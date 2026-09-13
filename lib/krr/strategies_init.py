# Shadow of robusta_krr/strategies/__init__.py, mounted into the pinned KRR image by lib/shell/krr.sh.
# KRR registers strategies via BaseStrategy.__subclasses__(), so one is only discovered once its module is
# imported. Hence the two upstream imports are re-added here alongside ours.
# A KRR image bump that ships a new built-in strategy needs its import added here too.

from .simple import SimpleStrategy
from .simple_limit import SimpleLimitStrategy
from .conservative import ConservativeStrategy
