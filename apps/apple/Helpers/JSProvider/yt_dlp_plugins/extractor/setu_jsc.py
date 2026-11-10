"""Browser Setu's JavaScript challenge provider for yt-dlp.

Solves YouTube's n / signature challenges with the setu-jsc helper (Apple JavaScriptCore, in its own App-Sandboxed process) so no Deno, Node or other runtime has to be installed.

What it depends on, and how that is kept safe:
  * yt-dlp's PUBLIC provider API only (yt_dlp.extractor.youtube.jsc.provider: JsChallengeProvider, requests, responses, register_*). Nothing from yt-dlp's private EJS classes is imported.
  * The yt_dlp_ejs solver scripts (the `lib` and `core` JavaScript yt-dlp itself ships). Their exact bytes are pinned below by SHA-256: a different EJS release is NOT used, it makes this provider
    unavailable and yt-dlp carries on with its other providers. The one unavoidable EJS-specific piece, how those scripts are called, is the small versioned adapter `ejs_script_v1`.
  * The setu-jsc helper, spoken to through a strict, versioned protocol (`--version` handshake, bounded input/output/time, schema-validated answer).
COMPATIBILITY below is the single record of what this release was verified against; scripts/check-media-tools.sh and the tests read it from here.
"""
import hashlib
import json
import os
import re
import subprocess

COMPATIBILITY = {
    'provider': '1.1.0',
    'helperProtocol': 1,
    'ytDlp': ['2026.10.26'],
    'ejs': {'0.8.0': {'lib': 'c55987fe697e5b9ee18830163f7af85327e9bb5c3e674b969d38c8d205eaa577', 'core': '18da6ce0758b416e7ae645084f4f8801f9f9d59d6c477c05eaa0ff94ebd8cc00'}},
    'scriptContract': 1,
    'challengeTypes': ['n', 'sig'],
}

SOLVE_SECONDS = 45            # the whole helper run, enforced here AND (a little later) by the helper itself
HANDSHAKE_SECONDS = 5
MAX_SCRIPT_BYTES = 16 << 20   # the helper refuses more
MAX_ANSWER_BYTES = 8 << 20
MAX_RESULT_CHARS = 4096
ERROR_TEXT_CHARS = 300
CIRCUIT_BREAKER = 2           # consecutive helper failures (timeout / crash / limit / protocol) before this run stops trying


# ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
# Pure functions: no yt-dlp import, tested on their own.
# ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

def sha256_text(text):
    return hashlib.sha256(text.encode('utf-8')).hexdigest()


def clean_text(value, limit=ERROR_TEXT_CHARS):
    """Text that came from the helper (and so, indirectly, from a web page's script) before it can reach a log or an error dialog: printable ASCII only, one line, short."""
    text = re.sub(r'[^\x20-\x7e]+', ' ', str(value))
    return ' '.join(text.split())[:limit]


def check_pairing(ytdlp_version, ejs_version, lib_code, core_code, matrix=None):
    """None when this exact yt-dlp + EJS scripts pairing is the one verified; otherwise a short reason."""
    matrix = matrix or COMPATIBILITY
    if ytdlp_version not in matrix['ytDlp']:
        return f'yt-dlp {ytdlp_version} has not been verified with this provider (verified: {", ".join(matrix["ytDlp"])})'
    pins = matrix['ejs'].get(ejs_version)
    if not pins:
        return f'yt-dlp-ejs {ejs_version} has not been verified with this provider (verified: {", ".join(matrix["ejs"])})'
    if sha256_text(lib_code) != pins['lib'] or sha256_text(core_code) != pins['core']:
        return f'the yt-dlp-ejs {ejs_version} solver scripts differ from the verified ones'
    return None


def parse_handshake(text, matrix=None):
    """(version, reason): the helper's `--version` line must be `setu-jsc <x.y.z> protocol <n>` with the protocol this provider speaks."""
    matrix = matrix or COMPATIBILITY
    m = re.fullmatch(r'setu-jsc (\d+\.\d+\.\d+) protocol (\d+)\s*', text or '')
    if not m:
        return None, 'the helper did not identify itself'
    if int(m.group(2)) != matrix['helperProtocol']:
        return None, f'the helper speaks protocol {m.group(2)}, this provider needs {matrix["helperProtocol"]}'
    return m.group(1), None


def ejs_script_v1(lib_code, core_code, player, groups):
    """Adapter for the EJS solver scripts, contract 1 (as yt-dlp's own EJS runtimes call them): the lib, the core, then one jsc(...) call printing JSON.
    `groups` is a list of (type, [challenges]). The preprocessed-player output is not requested: it is megabytes yt-dlp does not use."""
    data = {'type': 'player', 'player': player, 'requests': [{'type': t, 'challenges': list(c)} for t, c in groups], 'output_preprocessed': False}
    return f'{lib_code}\nObject.assign(globalThis, lib);\n{core_code}\nconsole.log(JSON.stringify(jsc({json.dumps(data)})));\n'


class AnswerError(Exception):
    pass


def validate_answer(text, groups):
    """Strict schema check of what the helper printed. Returns, per group, either ('ok', {challenge: solved}) or ('error', message). Anything else raises AnswerError."""
    if len(text.encode('utf-8', 'replace')) > MAX_ANSWER_BYTES:
        raise AnswerError('the answer is larger than allowed')
    try:
        out = json.loads(text)
    except (ValueError, RecursionError):           # RecursionError: a hostile script can print deeply nested brackets
        raise AnswerError('the answer is not JSON') from None
    if not isinstance(out, dict) or out.get('type') not in ('result', 'error'):
        raise AnswerError('the answer has no valid "type"')
    if out['type'] == 'error':
        raise AnswerError('the solver reported: ' + clean_text(out.get('error')))
    responses = out.get('responses')
    if not isinstance(responses, list) or len(responses) != len(groups):
        raise AnswerError(f'expected {len(groups)} responses, got {len(responses) if isinstance(responses, list) else "none"}')
    result = []
    for resp, (_, challenges) in zip(responses, groups):
        if not isinstance(resp, dict) or resp.get('type') not in ('result', 'error'):
            raise AnswerError('a response has no valid "type"')
        if resp['type'] == 'error':
            result.append(('error', clean_text(resp.get('error'))))
            continue
        data = resp.get('data')
        if not isinstance(data, dict) or not all(isinstance(k, str) and isinstance(v, str) and len(v) <= MAX_RESULT_CHARS for k, v in data.items()):
            raise AnswerError('a response carries data that is not text-to-text')
        if not set(data) <= set(challenges):
            raise AnswerError('a response answers a challenge that was not asked')
        if set(data) != set(challenges):
            result.append(('error', 'the solver answered only some of the challenges'))      # a partial answer is a failure of that request, never a success
            continue
        result.append(('ok', data))
    return result


# ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
# The provider
# ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

def _helper_path():
    # <App>/Contents/Resources/YtDlpPlugins/setu/yt_dlp_plugins/extractor/setu_jsc.py  ->  <App>/Contents/Helpers/setu-jsc
    contents = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), *(['..'] * 5)))
    return os.path.join(contents, 'Helpers', 'setu-jsc')


try:
    from yt_dlp.extractor.youtube.jsc.provider import (  # the documented public API
        JsChallengeProvider,
        JsChallengeProviderError,
        JsChallengeProviderRejectedRequest,
        JsChallengeProviderResponse,
        JsChallengeResponse,
        JsChallengeType,
        NChallengeOutput,
        SigChallengeOutput,
        register_preference,
        register_provider,
    )
    from yt_dlp.utils import Popen
except ImportError:                      # not inside yt-dlp (tests of the pure functions): the provider class is simply not defined
    JsChallengeProvider = None

if JsChallengeProvider is not None:
    _breaker = {'failures': 0, 'open': False}

    @register_provider
    class SetuJSCJCP(JsChallengeProvider):
        PROVIDER_VERSION = COMPATIBILITY['provider']
        BUG_REPORT_LOCATION = 'Browser Setu > Help > Report a problem'
        _SUPPORTED_TYPES = (JsChallengeType.N, JsChallengeType.SIG)

        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            self._checked = None          # (ok, reason, scripts)

        # -- availability: cheap, cached, no network -------------------------------------------------------------------------------------------------------------------------------------------
        def _check(self):
            if self._checked is not None:
                return self._checked
            self._checked = (False, 'unknown', None)
            reason, scripts = None, None
            path = _helper_path()
            if not (os.path.isfile(path) and os.access(path, os.X_OK)):
                reason = 'the helper is not in this app'
            else:
                try:
                    p = subprocess.run([path, '--version'], capture_output=True, timeout=HANDSHAKE_SECONDS, env={'PATH': '/usr/bin:/bin'})
                    _, reason = parse_handshake(p.stdout.decode('utf-8', 'replace')) if p.returncode == 0 else (None, 'the helper did not start')
                except Exception:
                    reason = 'the helper did not answer'
            if reason is None:
                try:
                    import yt_dlp_ejs
                    import yt_dlp_ejs.yt.solver as solver
                    from yt_dlp.version import __version__ as ytdlp_version
                    lib_code, core_code = solver.lib(), solver.core()
                    reason = check_pairing(ytdlp_version, str(yt_dlp_ejs.version), lib_code, core_code)
                    scripts = (lib_code, core_code)
                except Exception as e:     # missing package or a different layout: not verified, so not used
                    reason = f'the yt-dlp-ejs solver scripts could not be read ({type(e).__name__})'
            if reason:
                self.logger.warning(f'Browser Setu\'s JavaScript provider is not used: {reason}. Other JavaScript providers, if any, are tried instead.')
            self._checked = (reason is None, reason, scripts)
            return self._checked

        def is_available(self):
            return (not _breaker['open']) and self._check()[0]

        # -- solving ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------
        def _real_bulk_solve(self, requests):
            ok, _, scripts = self._check()
            if not ok:
                raise JsChallengeProviderRejectedRequest('Browser Setu\'s JavaScript provider is not available', expected=True)
            lib_code, core_code = scripts
            by_player = {}
            for request in requests:
                by_player.setdefault(request.input.player_url, []).append(request)
            for player_url, reqs in by_player.items():
                player = self._get_player(next((r.video_id for r in reqs), None), player_url)
                groups = [(r.type.value, r.input.challenges) for r in reqs]
                script = ejs_script_v1(lib_code, core_code, player, groups)
                if len(script.encode('utf-8')) > MAX_SCRIPT_BYTES:
                    raise JsChallengeProviderRejectedRequest('the player is larger than the helper accepts', expected=True)
                self.logger.info('Solving JS challenges using Browser Setu\'s JavaScriptCore helper')
                try:
                    results = validate_answer(self._run(script), groups)
                except (JsChallengeProviderError, JsChallengeProviderRejectedRequest):
                    raise                                              # already classified
                except AnswerError as e:
                    self._fail('protocol', str(e))
                except Exception as e:                                 # anything unforeseen is still a classified failure, never an unhandled exception inside yt-dlp
                    self._fail('internal', type(e).__name__)
                _breaker['failures'] = 0
                for request, (kind, value) in zip(reqs, results):
                    if kind == 'error':
                        yield JsChallengeProviderResponse(request, None, JsChallengeProviderError(f'[solver] {value}', expected=False))
                    else:
                        out = NChallengeOutput(value) if request.type is JsChallengeType.N else SigChallengeOutput(value)
                        yield JsChallengeProviderResponse(request, JsChallengeResponse(request.type, out))

        def _fail(self, kind, detail, infrastructure=True):
            """Raise a classified error. Helper failures that look systematic open a breaker so one broken run does not wait out the same deadline for every video."""
            if infrastructure:
                _breaker['failures'] += 1
                if _breaker['failures'] >= CIRCUIT_BREAKER:
                    _breaker['open'] = True
                    self.logger.warning('Browser Setu\'s JavaScript helper failed repeatedly; it will not be used again in this run.')
            raise JsChallengeProviderError(f'[{kind}] {clean_text(detail)}', expected=False)

        def _run(self, script):
            cmd = [_helper_path(), '--deadline', str(SOLVE_SECONDS + 5), '-']
            self.logger.debug(f'Running setu-jsc ({len(script)} characters of script)')       # never the script, the player or any page data
            try:
                with Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env={'PATH': '/usr/bin:/bin'}) as proc:
                    raw_out, raw_err = proc.communicate_or_kill(script.encode('utf-8'), timeout=SOLVE_SECONDS)
                    code = proc.returncode
                stdout, stderr = raw_out.decode('utf-8', 'replace'), raw_err.decode('utf-8', 'replace')
            except subprocess.TimeoutExpired:
                self._fail('timeout', f'the helper did not finish within {SOLVE_SECONDS} seconds and was ended')
            except OSError as e:
                self._fail('crash', f'the helper could not be started ({e.__class__.__name__})')
            if code != 0:
                tail = clean_text(stderr)
                kinds = {1: ('js-error', False), 2: ('input', False), 3: ('unsandboxed', True), 4: ('output-limit', True), 5: ('memory-limit', True)}
                kind, infra = kinds.get(code, ('deadline' if code in (-14, -24) else 'crash', True))
                self._fail(kind, f'exit status {code}' + (f': {tail}' if tail else ''), infrastructure=infra)
            if stderr and stderr.strip():
                self._fail('protocol', 'the helper wrote diagnostics instead of an answer: ' + clean_text(stderr))
            return stdout

    @register_preference(SetuJSCJCP)
    def _preference(provider, requests) -> int:
        return 1100            # tried before yt-dlp's own Deno provider (1000): ours ships with the app and is sandboxed
