"""PROTOTYPE - Browser Setu's JavaScript challenge provider for yt-dlp (experiments/ only; not shipped or wired into any production flow).

Solves YouTube's n / signature challenges with the setu-jsc helper (Apple JavaScriptCore, run in its own App-Sandboxed process) instead of an external Deno/Node. It reuses yt-dlp's own
EJS machinery unchanged: the solver scripts and their hash checks, request grouping and response parsing all come from yt_dlp's EJSBaseJCP; this class only says WHERE the runtime is and
HOW to start it (script on stdin, result on stdout, any stderr = failure: the same contract as yt-dlp's Deno and Node providers).
"""
import os

from yt_dlp.extractor.youtube.jsc._builtin.ejs import EJSBaseJCP
from yt_dlp.extractor.youtube.jsc.provider import JsChallengeProviderError, register_preference, register_provider
from yt_dlp.utils import Popen
from yt_dlp.utils._jsruntime import JsRuntimeInfo

import subprocess

_ENV_PATH = 'BROWSERSETU_JSC'


@register_provider
class SetuJSCJCP(EJSBaseJCP):
    PROVIDER_VERSION = '0.1.0'
    BUG_REPORT_LOCATION = 'Browser Setu > Help > Report a problem'
    JS_RUNTIME_NAME = 'setu-jsc'

    @property
    def runtime_info(self):
        path = os.environ.get(_ENV_PATH)
        if not path or not os.path.isfile(path) or not os.access(path, os.X_OK):
            return None            # not available: yt-dlp moves on to its next provider (Deno, Node...) as usual
        return JsRuntimeInfo(name='setu-jsc', path=path, version='0.1.0', version_tuple=(0, 1, 0))

    def _run_js_runtime(self, stdin: str, /) -> str:
        cmd = [self.runtime_info.path, '-']
        self.logger.debug(f'Running setu-jsc: {" ".join(cmd)}')
        with Popen(cmd, text=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as proc:
            stdout, stderr = proc.communicate_or_kill(stdin)
            if proc.returncode or stderr:
                msg = f'Error running setu-jsc (returncode: {proc.returncode})'
                if stderr:
                    msg = f'{msg}: {stderr.strip()}'
                raise JsChallengeProviderError(msg)
        return stdout


@register_preference(SetuJSCJCP)
def preference(provider, requests) -> int:
    return 1100            # tried before the built-in Deno provider (1000): ours is sandboxed and ships with the app
