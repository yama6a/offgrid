# Replaces robusta_krr/strategies/__init__.py in the pinned KRR image. lib/shell/krr.sh mounts it.
# KRR finds a strategy through BaseStrategy.__subclasses__(), so it sees only strategies whose module is imported.
# So this file imports the two upstream strategies as well as ours.
# When a KRR image bump adds a built-in strategy, add its import here too.

from .simple import SimpleStrategy
from .simple_limit import SimpleLimitStrategy
from .conservative import ConservativeStrategy
