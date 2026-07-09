# Custom KRR strategy for RAM-constrained nodes (this cluster: 3x 8GB Pi 5).
#
# The built-in `simple` strategy sets memory request == limit == peak + buffer. On scarce RAM that's
# wasteful: `request` is what the scheduler RESERVES, so requesting the peak permanently books memory that
# is rarely used and tanks pod density. This strategy splits the two:
#
#   memory REQUEST = max(AVERAGE working-set, request-floor)   -> scheduler packs on typical use, not peak (floor 16Mi)
#   memory LIMIT   = max(PEAK * (1 + buffer%), limit-floor)     -> per-pod safety ceiling (+20%, floor 32Mi)
#   CPU            = unchanged from `simple` (request = Nth percentile, limit unset; CPU is compressible)
#
# The two floors are ASYMMETRIC (request 16Mi < limit 32Mi), which KRR's single --mem-min can't express, so we
# floor inside the strategy and run with --mem-min 0 (see lib/shell/krr.sh). Request floor = idle working set
# (avoid scheduler overcommit); limit floor = cold-start/GC headroom (the OOM-safety floor).
#
# Deliberate trade-off: requests no longer cover the peak, so if several pods peak at once the node can run
# out of physical RAM and the kernel / node-pressure eviction OOM-kills a pod even though each is under its
# own limit. Accepted to buy density on scarce RAM; keep a node eviction headroom and watch for OOMKills.
#
# Loaded by mounting this file + a strategies/__init__.py that imports it into the pinned KRR image (see
# lib/shell/krr.sh). Written against KRR v1.28.0 internals; revisit on an image bump. Modelled on the
# upstream simple.py so the CPU path and the data-sufficiency/HPA guards behave identically.

import textwrap

import numpy as np
import pydantic as pd

from robusta_krr.core.abstract.strategies import (
    BaseStrategy,
    K8sObjectData,
    MetricsPodData,
    PodsTimeData,
    ResourceRecommendation,
    ResourceType,
    RunResult,
    StrategySettings,
)
from robusta_krr.core.integrations.prometheus.metrics import (
    CPUAmountLoader,
    MaxMemoryLoader,
    MaxOOMKilledMemoryLoader,
    MemoryAmountLoader,
    PercentileCPULoader,
    PrometheusMetric,
)


class AvgMemoryLoader(PrometheusMetric):
    """Average working-set memory per pod over the window (mirrors MaxMemoryLoader, avg_over_time not max_over_time)."""

    def get_query(self, object: K8sObjectData, duration: str, step: str) -> str:
        pods_selector = "|".join(pod.name for pod in object.pods)
        cluster_label = self.get_prometheus_cluster_label()
        return f"""
            avg_over_time(
                max(
                    container_memory_working_set_bytes{{
                        namespace="{object.namespace}",
                        pod=~"{pods_selector}",
                        container="{object.container}"
                        {cluster_label}
                    }}
                ) by (container, pod, job)
                [{duration}:{step}]
            )
        """


class ConservativeStrategySettings(StrategySettings):
    cpu_percentile: float = pd.Field(95, gt=0, le=100, description="The percentile to use for the CPU request.")
    memory_limit_buffer_percentage: float = pd.Field(
        20, gt=0, description="Percent buffer added to PEAK memory usage for the memory LIMIT."
    )
    memory_request_min: int = pd.Field(
        16, ge=0, description="Floor for the memory REQUEST in Mi: request = max(average usage, this)."
    )
    memory_limit_min: int = pd.Field(
        32, ge=0, description="Floor for the memory LIMIT in Mi: limit = max(peak + buffer, this)."
    )
    points_required: int = pd.Field(
        100, ge=1, description="The number of data points required to make a recommendation for a resource."
    )
    allow_hpa: bool = pd.Field(
        False, description="Whether to recommend even when an HPA is defined on that resource."
    )
    use_oomkill_data: bool = pd.Field(
        False, description="Whether to bump the memory LIMIT when OOMKills are detected (experimental)."
    )
    oom_memory_buffer_percentage: float = pd.Field(
        25, ge=0, description="Percent to increase the memory LIMIT above the OOMKilled limit when OOMKills occurred."
    )

    def calculate_cpu_proposal(self, data: PodsTimeData) -> float:
        if len(data) == 0:
            return float("NaN")
        if len(data) > 1:
            data_ = np.concatenate([values[:, 1] for values in data.values()])
        else:
            data_ = list(data.values())[0][:, 1]
        return np.max(data_)

    def calculate_memory_request(self, avg_data: PodsTimeData) -> float:
        # per-pod average, then the busiest replica's average (so no replica is under-requested vs its own typical use)
        data_ = [np.max(values[:, 1]) for values in avg_data.values()]
        if len(data_) == 0:
            return float("NaN")
        # request = max(average usage, floor). Floor reflects the idle working set so the scheduler doesn't overcommit.
        return max(np.max(data_), self.memory_request_min * 1024**2)

    def calculate_memory_limit(self, max_data: PodsTimeData, max_oomkill: float = 0) -> float:
        data_ = [np.max(values[:, 1]) for values in max_data.values()]
        if len(data_) == 0:
            return float("NaN")
        # limit = max(peak + buffer, OOMKilled-limit + its buffer, floor). An OOMKill proves the ceiling was too low;
        # the floor gives tiny pods cold-start/GC headroom (this is the OOM-safety floor, higher than the request floor).
        return max(
            np.max(data_) * (1 + self.memory_limit_buffer_percentage / 100),
            max_oomkill * (1 + self.oom_memory_buffer_percentage / 100),
            self.memory_limit_min * 1024**2,
        )


class ConservativeStrategy(BaseStrategy[ConservativeStrategySettings]):

    display_name = "conservative"
    rich_console = True

    @property
    def metrics(self) -> list[type[PrometheusMetric]]:
        metrics = [
            PercentileCPULoader(self.settings.cpu_percentile),
            MaxMemoryLoader,
            AvgMemoryLoader,
            CPUAmountLoader,
            MemoryAmountLoader,
        ]
        if self.settings.use_oomkill_data:
            metrics.append(MaxOOMKilledMemoryLoader)
        return metrics

    @property
    def description(self):
        s = textwrap.dedent(f"""\
            RAM-constrained strategy: memory request = average, limit = peak + buffer (split, unlike `simple`).
            CPU request: {self.settings.cpu_percentile}% percentile, limit: unset
            Memory request: max(average, {self.settings.memory_request_min}Mi); limit: max(peak + {self.settings.memory_limit_buffer_percentage}%, {self.settings.memory_limit_min}Mi){" + OOMKill floor" if self.settings.use_oomkill_data else ""}
            History: {self.settings.history_duration} hours
            Step: {self.settings.timeframe_duration} minutes

            Customize e.g. `krr conservative --cpu_percentile=90 --memory_limit_buffer_percentage=25 --history_duration=336`
            """)
        if not self.settings.allow_hpa:
            s += "\n" + textwrap.dedent("""\
                This strategy does not work with objects with HPA defined (Horizontal Pod Autoscaler).
                If HPA is defined for CPU or Memory, the strategy will return "?" for that resource.
                You can override this behaviour by passing the --allow-hpa flag
                """)
        return s

    def __calculate_cpu_proposal(
        self, history_data: MetricsPodData, object_data: K8sObjectData
    ) -> ResourceRecommendation:
        data = history_data["PercentileCPULoader"]
        if len(data) == 0:
            return ResourceRecommendation.undefined(info="No data")

        data_count = {pod: values[0, 1] for pod, values in history_data["CPUAmountLoader"].items()}
        total_points_count = sum(data_count.values())
        if total_points_count < self.settings.points_required:
            return ResourceRecommendation.undefined(info="Not enough data")

        if (
            object_data.hpa is not None
            and object_data.hpa.target_cpu_utilization_percentage is not None
            and not self.settings.allow_hpa
        ):
            return ResourceRecommendation.undefined(info="HPA detected")

        return ResourceRecommendation(request=self.settings.calculate_cpu_proposal(data), limit=None)

    def __calculate_memory_proposal(
        self, history_data: MetricsPodData, object_data: K8sObjectData
    ) -> ResourceRecommendation:
        max_data = history_data["MaxMemoryLoader"]
        avg_data = history_data["AvgMemoryLoader"]

        oomkill_detected = False
        if self.settings.use_oomkill_data:
            oom_data = history_data["MaxOOMKilledMemoryLoader"]
            max_oomkill_value = np.max([values[0, 1] for values in oom_data.values()]) if len(oom_data) > 0 else 0
            oomkill_detected = max_oomkill_value != 0
        else:
            max_oomkill_value = 0

        if len(max_data) == 0 or len(avg_data) == 0:
            return ResourceRecommendation.undefined(info="No data")

        data_count = {pod: values[0, 1] for pod, values in history_data["MemoryAmountLoader"].items()}
        total_points_count = sum(data_count.values())
        if total_points_count < self.settings.points_required:
            return ResourceRecommendation.undefined(info="Not enough data")

        if (
            object_data.hpa is not None
            and object_data.hpa.target_memory_utilization_percentage is not None
            and not self.settings.allow_hpa
        ):
            return ResourceRecommendation.undefined(info="HPA detected")

        return ResourceRecommendation(
            request=self.settings.calculate_memory_request(avg_data),
            limit=self.settings.calculate_memory_limit(max_data, max_oomkill_value),
            info="OOMKill detected" if oomkill_detected else None,
        )

    def run(self, history_data: MetricsPodData, object_data: K8sObjectData) -> RunResult:
        return {
            ResourceType.CPU: self.__calculate_cpu_proposal(history_data, object_data),
            ResourceType.Memory: self.__calculate_memory_proposal(history_data, object_data),
        }
