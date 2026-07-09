# Shadow of robusta_krr/strategies/__init__.py, mounted into the pinned KRR image by lib/shell/krr.sh.
# KRR registers strategies via BaseStrategy.__subclasses__(), so a strategy is only discovered once its
# module is imported. This re-adds the two upstream imports and appends our custom `conservative` strategy.
# If a KRR image bump ships a new built-in strategy, add its import here too (we pin the image, so no surprise).

from .simple import SimpleStrategy
from .simple_limit import SimpleLimitStrategy
from .conservative import ConservativeStrategy
