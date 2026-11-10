#!/usr/bin/env python3
"""Whether a Bash command's curl or wget uploads to a host outside the team's own.

Usage: python3 -I outbound.py   (the command on stdin; prints the reason when it uploads)

bin/hooks/command-guard runs this file on a Bash call's code text, as bin/lib/command_text.py
prints it, and refuses the call when it prints a reason; so every role whose settings layer on
settings/worker.json gets the refusal, ops among them. It exits 0 either way; input that is not
UTF-8, or an error of its own, exits 1 naming it on stderr, so the hook refuses: a guard that
cannot decide refuses.
It reads each simple command of the command (command_text.simple_commands: those in a group, a
substitution, a pipeline or a list too), past its assignments and the wrappers env, command, exec,
nohup, time, nice, ionice, stdbuf, timeout, setsid, sudo, doas, xargs, parallel, watch and flock
with their options, numbers and flock's file, parallel's inputs after its ::: or :::: left out but
for those with a scheme (https://host/u), read as URLs. A command string is read where the tool
itself takes one: what watch and parallel join of their command's words (from the first word that
is no option, and the next too when an option may take that one), env's -S or --split-string
value with the words after it, and flock's -c or --command value, each after the assignments
before it, quoted. Else the command's name by its basename decides:
  - curl uploads with a request body or a file: -d, --data, --data-ascii, --data-binary,
    --data-urlencode, --data-raw, -F, --form, --form-string, --json, -T or --upload-file, each
    also as --expand-<flag>, a short one alone or in a cluster (-sSd@f), a long one as --flag
    value or --flag=value, whether its value is literal or an @file;
  - wget uploads with --post-data, --post-file, --body-data or --body-file, or a long option
    getopt takes as an abbreviation of one, or one of those set by -e or --execute (post_file=f);
  - a shell's -c string (bash, sh, zsh, dash or ksh), su's -c, -C, --command or
    --session-command, script's -c or --command, eval's words, and each command find's -exec,
    -execdir, -ok or -okdir runs are read as a command too; a -c string behind another command
    (docker exec web sh -c '...') is read on the code text, which adds it as a line of its own.
env's, flock's, su's and script's long options are taken by any prefix getopt_long takes as one
alone (su --comm), and their short ones in a cluster as getopt reads it (env -uSPATH is -u SPATH).
A command string is never read again when it is the command being read.
Each tool's options that take a value skip it, so a value is never read as a URL; an option it
does not know takes none.
A URL is curl's positional word, --url's value or a word after --, or wget's positional word; - is
stdin, not a URL. Its authority is what follows an optional scheme up to the first /, ? or #, and
it counts only when that authority is a literal: one that, its quotes removed, holds no $ and no
backtick (nor is the URL a process substitution), since a host held in a variable ("$B/markets")
is not known here, though a variable in the path or query ("https://host/u?t=$RANDOM") is no
matter. Its host is that authority past any userinfo and before a port, a [...] IPv6 address kept
whole, lowercased; a host with no letter or digit (find's ; or +, a {}) is none. The team's own
hosts are the local ones: localhost, 127.x.y.z, ::1, [::1], 0:0:0:0:0:0:0:1, and 0.0.0.0, :: and
[::], which reach the local machine on Linux and macOS.
The request also goes through the hosts a proxy or an override names, each read as a URL is: curl's
-x, --proxy, --proxy1.0, --preproxy, --socks4, --socks4a, --socks5 and --socks5-hostname, the
third field of --connect-to (an empty one is the URL's own host) and the addresses of --resolve
(none for -HOST:PORT); wget's http_proxy, https_proxy and ftp_proxy set by -e; and for both, an
assignment before the command of a variable ending in _proxy, any case, no_proxy apart.
An upload is reported when one of its invocation's URLs or those hosts is a literal outside the
team's own; a request with no body (curl -X POST alone) is not an upload.
It is a speed bump, as command-guard's other refusals are: a host held in a variable, a body or URL
in a curl -K config, a URL in a wget -i list, a proxy exported earlier or set in a config file, a
script file a shell runs, ssh's remote command (it runs on the other host) and ssh itself, a
command another tool runs from its arguments (nsenter, chroot, unshare, systemd-run, tmux
send-keys), a command word built by a substitution ($(command -v curl)), a command given as one
string where its tool takes words (sudo -s escapes each word it passes its shell), another tool's
upload and an interpreter's own request go unseen, held by auto mode and the role's rule against
reaching a refused thing another way.
"""

import os
import re
import shlex
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from command_text import simple_commands  # noqa: E402

REASON = "an upload to a host outside the team's own; a file's contents never go to an outside host"

ASSIGNMENT = re.compile(r"[A-Za-z_]\w*\+?=")
NUMBER = re.compile(r"[0-9][0-9.]*[smhd]?")
WRAPPERS = frozenset(
    "env command exec nohup time nice ionice stdbuf timeout setsid sudo doas xargs parallel watch"
    " flock".split()
)
SHELLS = frozenset("bash sh zsh dash ksh".split())
TOOLS = frozenset(("curl", "wget", "eval", "su", "script", "find")) | SHELLS

# curl 8's flags that send a body or a file, and its options that take a value (curl --help all).
CURL_UPLOAD_SHORT = frozenset("dFT")
CURL_UPLOAD_LONG = frozenset(
    "data data-ascii data-binary data-urlencode data-raw form form-string json upload-file".split()
)
CURL_VALUE_SHORT = frozenset("EKCbcdDFPHhmoxUQreXYytzTuAw")
CURL_VALUE_LONG = frozenset(
    """
    abstract-unix-socket alt-svc aws-sigv4 cacert capath cert cert-type ciphers config
    connect-timeout connect-to continue-at cookie cookie-jar create-file-mode crlfile curves data
    data-ascii data-binary data-raw data-urlencode delegation dns-interface dns-ipv4-addr
    dns-ipv6-addr dns-servers doh-url dump-header ech egd-file engine etag-compare etag-save
    expect100-timeout form form-string ftp-account ftp-alternative-to-user ftp-method ftp-port
    ftp-ssl-ccc-mode happy-eyeballs-timeout-ms haproxy-clientip header help hostpubmd5
    hostpubsha256 hsts interface ip-tos ipfs-gateway json keepalive-cnt keepalive-time key key-type
    knownhosts krb libcurl limit-rate local-port login-options mail-auth mail-from mail-rcpt
    max-filesize max-redirs max-time netrc-file noproxy oauth2-bearer output output-dir
    parallel-max parallel-max-host pass pinnedpubkey preproxy proto proto-default proto-redir proxy
    proxy1.0
    proxy-cacert proxy-capath proxy-cert proxy-cert-type proxy-ciphers proxy-crlfile proxy-header
    proxy-key proxy-key-type proxy-pass proxy-pinnedpubkey proxy-service-name proxy-tls13-ciphers
    proxy-tlsauthtype proxy-tlspassword proxy-tlsuser proxy-user pubkey quote random-file range
    rate referer request request-target resolve retry retry-delay retry-max-time sasl-authzid
    service-name sigalgs socks4 socks4a socks5 socks5-gssapi-service socks5-hostname speed-limit
    speed-time ssl-sessions stderr telnet-option tftp-blksize time-cond tls-max tls13-ciphers
    tlsauthtype tlspassword tlsuser trace trace-ascii trace-config unix-socket upload-file
    upload-flags url url-query user user-agent variable vlan-priority write-out
    """.split()
)

# curl's options whose value is a host the request goes through: a proxy, or a connect override's
# or a resolve's target.
CURL_PROXY_SHORT = frozenset("x")
CURL_PROXY_LONG = frozenset("proxy proxy1.0 preproxy socks4 socks4a socks5 socks5-hostname".split())

# wget 1's flags that send a body, and its long options (wget --help), those taking a value apart;
# getopt takes a long one by any prefix that names one alone.
WGET_UPLOAD = ("post-data", "post-file", "body-data", "body-file")
WGET_VALUE_SHORT = frozenset("eoaiBtOTwQPlARDIX")
WGET_VALUE_LONG = frozenset(
    """
    execute output-file append-output report-speed input-file base config rejected-log tries
    retry-on-http-error output-document start-pos progress timeout dns-timeout connect-timeout
    read-timeout wait waitretry quota bind-address limit-rate restrict-file-names prefer-family user
    password use-askpass local-encoding remote-encoding directory-prefix cut-dirs http-user
    http-password default-page header compression proxy-user proxy-password referer user-agent
    load-cookies save-cookies post-data post-file method body-data body-file secure-protocol
    certificate certificate-type private-key private-key-type ca-certificate ca-directory crl-file
    pinnedpubkey ciphers ftp-user ftp-password warc-file warc-header warc-max-size warc-dedup
    warc-tempdir level backups accept reject accept-regex reject-regex regex-type domains
    exclude-domains follow-tags ignore-tags include-directories exclude-directories
    """.split()
)
WGET_LONG = WGET_VALUE_LONG | frozenset(
    """
    adjust-extension ask-password auth-no-challenge background backup-converted content-disposition
    content-on-error continue convert-file-only convert-links debug delete-after follow-ftp
    force-directories force-html ftps-clear-data-connection ftps-fallback-to-ftp ftps-implicit
    ftps-resume-ssl help hsts-file https-only ignore-case ignore-length inet4-only inet6-only
    keep-session-cookies max-redirect mirror no-cache no-check-certificate no-clobber no-config
    no-cookies no-directories no-dns-cache no-glob no-host-directories no-hsts no-http-keep-alive
    no-if-modified-since no-iri no-netrc no-parent no-passive-ftp no-proxy no-remove-listing
    no-use-server-timestamps no-verbose no-warc-compression no-warc-digests no-warc-keep-log
    page-requisites preserve-permissions protocol-directories quiet random-wait recursive relative
    retr-symlinks retry-connrefused retry-on-host-error save-headers server-response show-progress
    span-hosts spider strict-comments timestamping trust-server-names unlink verbose version xattr
    """.split()
)
# The wgetrc commands, as -e runs them, that set a body or a proxy: a name is read with case, -, _
# and blanks ignored.
WGET_UPLOAD_COMMANDS = frozenset(("postdata", "postfile", "bodydata", "bodyfile"))
WGET_PROXY_COMMANDS = frozenset(("httpproxy", "httpsproxy", "ftpproxy"))
# An assignment of a proxy curl or wget reads from the environment (http_proxy, ALL_PROXY), but
# no_proxy.
PROXY_ASSIGNMENT = re.compile(r"(?i)(?!no_proxy=)\w*_proxy=")
# The tools with an option whose value is the command they run as one string: its short names, its
# long names, all the tool's long options (getopt_long takes one by any prefix that names it
# alone), and its short options that take a value, so a cluster is read as getopt reads it
# (env -uSPATH is -u SPATH). env and flock are wrappers, su and script commands of their own.
STRING_OPTIONS = {
    "env": (
        "S",
        {"split-string"},
        frozenset(
            "ignore-environment null unset chdir split-string block-signal default-signal"
            " ignore-signal list-signal-handling debug help version argv0".split()
        ),
        "aCSu",
    ),
    "flock": (
        "c",
        {"command"},
        frozenset(
            "shared exclusive write unlock nonblock nb timeout wait conflict-exit-code close"
            " command no-fork fcntl verbose help version".split()
        ),
        "Ecw",
    ),
    "su": (
        "cC",
        {"command", "session-command"},
        frozenset(
            "command session-command fast login group supp-group preserve-environment pty shell"
            " whitelist-environment help version".split()
        ),
        "cCgGsw",
    ),
    "script": (
        "c",
        {"command"},
        frozenset(
            "append command echo log-in log-out log-io log-timing logging-format return flush force"
            " quiet timing output-limit help version".split()
        ),
        "BEIOTcmo",
    ),
}
# The wrappers that join their command's words into one string a shell runs.
JOINING = frozenset(("watch", "parallel"))
# find's actions that run a command, its words up to a ; or a +.
FIND_EXEC = frozenset(("-exec", "-execdir", "-ok", "-okdir"))
# parallel's separators, after which its words are inputs, not the command's.
PARALLEL_INPUTS = frozenset((":::", "::::", ":::+", "::::+"))

SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*://")
LOOPBACK = frozenset(
    ("localhost", "::1", "[::1]", "0:0:0:0:0:0:0:1", "[0:0:0:0:0:0:0:1]", "0.0.0.0", "::", "[::]")
)
LOOPBACK_V4 = re.compile(r"127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}")


def _long_options(name, options):
    """The long options name stands for, as getopt_long takes it: itself, or those it is a prefix
    of."""
    if name in options:
        return {name}
    return {option for option in options if option.startswith(name)} if name else set()


def _string_option(word, shorts, longs, options, values):
    """The value word gives an option that names a command as one string (env's -S, flock's -c):
    the text joined to it, "" when it is the next word, or None when word is not it."""
    if word.startswith("--"):
        name, eq, value = word[2:].partition("=")
        named = _long_options(name, options)
        return (value if eq else "") if len(named) == 1 and named <= longs else None
    if word.startswith("-") and word != "-":
        _, flag, joined = _short(word, values)
        return joined if flag and flag in shorts else None
    return None


def _assigned(assignments):
    """The assignments as a command's text puts them, each value quoted."""
    pairs = (assignment.partition("=") for assignment in assignments)
    return "".join(f"{name}={shlex.quote(value)} " for name, _, value in pairs)


def _joined(args, parallel):
    """The command strings watch or parallel may run of its words after its name: its command's
    words joined with blanks, unquoted, as the tool joins them, from its first word that is no
    option, and from the next one too when an option before it may take that word as its value;
    under parallel, only the words before its first ::: and the inputs with a scheme after it."""
    cut = len(args)
    if parallel:
        cut = next((k for k, word in enumerate(args) if word in PARALLEL_INPUTS), cut)
    inputs = [word for word in args[cut:] if SCHEME.match(word)]
    first = next((k for k in range(cut) if not args[k].startswith("-")), None)
    if first is None:
        return []
    starts = [first]
    if first and args[first - 1].startswith("-") and first + 1 < cut:
        starts.append(first + 1)
    return [" ".join(args[start:cut] + inputs) for start in starts]


def _command(words):
    """The assignments before the command's own name, env's among them, the words from that name
    on, past its wrappers, as the header says, and the command strings those wrappers run: a word
    after a wrapper's option is its value unless it names a command read here; env -S's and
    flock -c's value is a command string, and so is what watch and parallel join; under parallel,
    the words from its first ::: on are its inputs, left out but for those with a scheme, which its
    command takes as URLs."""
    i, n, inputs, strings = 0, len(words), False, []
    while i < n and ASSIGNMENT.match(words[i]):
        i += 1
    assignments = words[:i]
    while i < n and os.path.basename(words[i]) in WRAPPERS:
        wrapper = os.path.basename(words[i])
        file_left, option = wrapper == "flock", False
        inputs = inputs or wrapper == "parallel"
        if wrapper in JOINING:
            joined = _joined(words[i + 1 :], wrapper == "parallel")
            strings += [_assigned(assignments) + text for text in joined]
        i += 1
        while i < n:
            word = words[i]
            string = None
            if wrapper in STRING_OPTIONS:
                string = _string_option(word, *STRING_OPTIONS[wrapper])
            if string is not None:
                # The option's value, the rest of the word or the next word, is the command, the
                # words after it its arguments.
                rest = words[i + 1 :] if string else words[i + 2 :]
                string = string or (words[i + 1] if i + 1 < n else "")
                tail = " " + shlex.join(rest) if wrapper == "env" and rest else ""
                return assignments, [], strings + [_assigned(assignments) + string + tail]
            if ASSIGNMENT.match(word):
                assignments.append(word)
                option = False
            elif os.path.basename(word) in TOOLS | WRAPPERS:
                break
            elif word.startswith("-") and word != "-":
                option = True
            elif NUMBER.fullmatch(word):
                option = False
            elif option:
                option = False
            elif file_left:
                file_left = False
            else:
                break
            i += 1
    words = words[i:]
    if inputs:
        cut = next((k for k, word in enumerate(words) if word in PARALLEL_INPUTS), len(words))
        words = words[:cut] + [word for word in words[cut:] if SCHEME.match(word)]
    return assignments, words, strings


def _option_string(args, shorts, longs, options, values):
    """The value of the option of su or script that names the command they run as one string (-c
    alone or in a cluster, or a long one by its name or a prefix, with its value joined by = or
    next), or None."""
    for k, word in enumerate(args):
        if word == "--":
            break
        string = _string_option(word, shorts, longs, options, values)
        if string is not None:
            return string or (args[k + 1] if k + 1 < len(args) else "")
    return None


def _exec_commands(args):
    """The commands find's -exec, -execdir, -ok and -okdir run, each its words up to its ; or +."""
    commands, k = [], 0
    while k < len(args):
        if args[k] in FIND_EXEC:
            end = next((j for j in range(k + 1, len(args)) if args[j] in (";", "+")), len(args))
            commands.append(args[k + 1 : end])
            k = end
        k += 1
    return commands


def _short(word, value_flags):
    """A cluster of short options read as getopt reads it: its flags up to the first that takes a
    value, that flag or None, and the value joined to it ("" when it is the next word)."""
    for k, flag in enumerate(word[1:], 1):
        if flag in value_flags:
            return word[1:k], flag, word[k + 1 :]
    return word[1:], None, ""


def _fields(value):
    """A host:port:host:port value's fields, split at each : outside a [...] IPv6 address."""
    fields, field, bracket = [], [], False
    for c in value:
        bracket = (bracket or c == "[") and c != "]"
        if c == ":" and not bracket:
            fields.append("".join(field))
            field = []
        else:
            field.append(c)
    return fields + ["".join(field)]


def _curl_via(name, value):
    """The hosts a curl option with its value sends the request through: a proxy's, a connect
    override's target (HOST1:PORT1:HOST2:PORT2, an empty HOST2 the URL's own) or a resolve's
    addresses ([+]HOST:PORT:ADDRESS[,ADDRESS]..., none for -HOST:PORT, which drops one)."""
    if name in CURL_PROXY_LONG or name in CURL_PROXY_SHORT:
        return [value]
    if name == "connect-to":
        fields = _fields(value)
        return [fields[2]] if len(fields) > 2 and fields[2] else []
    if name == "resolve" and not value.startswith("-"):
        return ":".join(_fields(value.removeprefix("+"))[2:]).split(",")
    return []


def _curl(args):
    """Whether curl's arguments send a body or a file, its URLs and the hosts it goes through."""
    uploads, urls, via, k = False, [], [], 0
    while k < len(args):
        word = args[k]
        k += 1
        if word == "--":
            urls += args[k:]
            break
        if word.startswith("--"):
            name, eq, value = word[2:].partition("=")
            name = name.removeprefix("expand-")
            uploads = uploads or name in CURL_UPLOAD_LONG
            if name in CURL_VALUE_LONG and not eq:
                value = args[k] if k < len(args) else ""
                k += 1
            if name == "url":
                urls.append(value)
            via += _curl_via(name, value)
        elif word.startswith("-") and word != "-":
            flags, flag, value = _short(word, CURL_VALUE_SHORT)
            uploads = uploads or bool(set(flags + (flag or "")) & CURL_UPLOAD_SHORT)
            if flag and not value:
                value = args[k] if k < len(args) else ""
                k += 1
            via += _curl_via(flag, value)
        elif word != "-":
            urls.append(word)
    return uploads, urls, via


def _wgetrc(command):
    """A wgetrc command's name, its case, -, _ and blanks dropped, and its value."""
    name, _, value = command.partition("=")
    return re.sub(r"[-_\s]", "", name.lower()), value.strip()


def _wget(args):
    """Whether wget's arguments send a body, its URLs and the proxies -e sets."""
    uploads, urls, via, k = False, [], [], 0
    while k < len(args):
        word = args[k]
        k += 1
        if word == "--":
            urls += args[k:]
            break
        if word.startswith("--"):
            name, eq, value = word[2:].partition("=")
            options = _long_options(name, WGET_LONG)
            # A prefix of more than one option is refused by wget, so it sends nothing either way.
            uploads = uploads or bool(options & set(WGET_UPLOAD))
            if options and options <= WGET_VALUE_LONG and not eq:
                value = args[k] if k < len(args) else ""
                k += 1
            executes = options == {"execute"}
        elif word.startswith("-") and word != "-":
            _, flag, value = _short(word, WGET_VALUE_SHORT)
            if flag and not value:
                value = args[k] if k < len(args) else ""
                k += 1
            executes = flag == "e"
        else:
            urls.append(word)
            continue
        if executes:
            name, setting = _wgetrc(value)
            uploads = uploads or name in WGET_UPLOAD_COMMANDS
            via += [setting] if name in WGET_PROXY_COMMANDS else []
    return uploads, urls, via


def _shell_string(args):
    """The string a shell's -c runs, its first word after the options, or None when it has none."""
    runs, k = False, 0
    while k < len(args):
        word = args[k]
        k += 1
        if word == "--":
            break
        if word.startswith("--"):
            continue
        if len(word) > 1 and word[0] in "-+":
            runs = runs or (word[0] == "-" and "c" in word)
            # -o and -O take an option's name.
            k += word[-1] in "oO"
            continue
        return word if runs else None
    return args[k] if runs and k < len(args) else None


def _authority(url):
    """A URL's authority: what follows an optional scheme up to the first /, ? or #."""
    return re.split(r"[/?#]", SCHEME.sub("", url, count=1), maxsplit=1)[0]


def _host(authority):
    """The lowercased host of an authority, as the header says."""
    authority = authority.rpartition("@")[2].lower()
    if authority in LOOPBACK:
        return authority
    if authority.startswith("["):
        close = authority.find("]")
        return authority[: close + 1] if close >= 0 else authority
    return authority.rpartition(":")[0] if ":" in authority else authority


def _outside(url):
    """Whether a URL's authority is a literal whose host is outside the team's own; a host with no
    letter or digit (find's ; or +, a {}) is none."""
    authority = _authority(url)
    if "$" in authority or "`" in authority or url.startswith(("<(", ">(")):
        return False
    host = _host(authority)
    local = host in LOOPBACK or LOOPBACK_V4.fullmatch(host)
    return bool(re.search(r"[A-Za-z0-9]", host)) and not local


def _uploads(words, command):
    """Whether one simple command's words, of the command, upload to a host outside the team's own;
    a command string it runs is read in turn, unless it is the command itself."""

    def runs(text):
        return text is not None and text != command and outbound_upload(text) is not None

    assignments, words, strings = _command(words)
    if any(runs(text) for text in strings):
        return True
    if not words:
        return False
    name, args = os.path.basename(words[0]), words[1:]
    if name in ("curl", "wget"):
        uploads, urls, via = (_curl if name == "curl" else _wget)(args)
        via += [word.partition("=")[2] for word in assignments if PROXY_ASSIGNMENT.match(word)]
        return uploads and any(_outside(url) for url in urls + via)
    if name == "find":
        return any(_uploads(found, command) for found in _exec_commands(args))
    if name in SHELLS:
        return runs(_shell_string(args))
    if name in STRING_OPTIONS:
        return runs(_option_string(args, *STRING_OPTIONS[name]))
    return name == "eval" and runs(" ".join(args))


def outbound_upload(command: str) -> str | None:
    """The reason the command uploads to a host outside the team's own, or None when it does not."""
    return REASON if any(_uploads(words, command) for words in simple_commands(command)) else None


def main():
    try:
        reason = outbound_upload(sys.stdin.buffer.read().decode("utf-8"))
    except Exception as error:  # noqa: BLE001 - a guard that cannot decide refuses
        sys.stderr.write(f"outbound.py: {type(error).__name__}: {error}\n")
        return 1
    if reason:
        sys.stdout.write(reason + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
