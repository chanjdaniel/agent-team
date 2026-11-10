#!/usr/bin/env python3
"""Whether a Bash command's curl or wget uploads to a host outside the team's own loopback.

Usage: python3 -I outbound.py   (the command on stdin; prints the reason when it uploads, else nothing)

bin/hooks/command-guard runs this file on a Bash call's code text, as bin/lib/command_text.py
prints it, and refuses the call when it prints a reason. It exits 0 either way; input that is not
UTF-8, or an error of its own, exits 1 naming it on stderr, so the hook refuses: a guard that
cannot decide refuses.
It reads each simple command of the command (command_text.simple_commands: those in a group, a
substitution, a pipeline or a list too), past its assignments and the wrappers env, command, exec,
nohup, time, nice, ionice, stdbuf, timeout, setsid, sudo, doas, xargs, parallel, watch and flock
with their options, numbers and flock's file, and the command's name by its basename decides:
  - curl uploads with a request body or a file: -d, --data, --data-ascii, --data-binary,
    --data-urlencode, --data-raw, -F, --form, --form-string, --json, -T or --upload-file, each
    also as --expand-<flag>, a short one alone or in a cluster (-sSd@f), a long one as --flag
    value or --flag=value, whether its value is literal or an @file;
  - wget uploads with --post-data, --post-file, --body-data or --body-file, or a long option
    getopt takes as an abbreviation of one, or one of those set by -e or --execute (post_file=f);
  - a shell's -c string (bash, sh, zsh, dash or ksh) and eval's words are read as a command too.
Each tool's options that take a value skip it, so a value is never read as a URL; an option it
does not know takes none.
A URL is curl's positional word, --url's value or a word after --, or wget's positional word; - is
stdin, not a URL. It counts only as a literal: one that, its quotes removed, holds no $ and no
backtick (nor is a process substitution), since a host held in a variable ("$B/markets") is not
known here. Its host is what follows an optional scheme up to the first /, ? or #, past any
userinfo and before a port, a [...] IPv6 address kept whole, lowercased; the team's own is
localhost, 127.x.y.z, ::1, [::1] and 0:0:0:0:0:0:0:1.
An upload is reported when one of its invocation's URLs is a literal host outside the team's own;
a request with no body (curl -X POST alone) is not an upload.
It is a speed bump, as command-guard's other refusals are: a host held in a variable, a body or URL
in a curl -K config, a URL in a wget -i list, another tool and an interpreter's own request go unseen,
held by auto mode and the role's rule against reaching a refused thing another way.
"""

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from command_text import simple_commands  # noqa: E402

REASON = "an upload to a host outside the team's own; a file's contents never go to an outside host"

ASSIGNMENT = re.compile(r"[A-Za-z_]\w*\+?=")
NUMBER = re.compile(r"[0-9][0-9.]*[smhd]?")
WRAPPERS = frozenset("env command exec nohup time nice ionice stdbuf timeout setsid sudo doas xargs parallel watch flock".split())
SHELLS = frozenset("bash sh zsh dash ksh".split())
TOOLS = frozenset(("curl", "wget", "eval")) | SHELLS

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
# A wgetrc command that sets a body, as -e runs it: its name is read with case, - and _ ignored.
WGET_UPLOAD_COMMAND = re.compile(r"(?:postdata|postfile|bodydata|bodyfile)\s*=")

SCHEME = re.compile(r"[A-Za-z][A-Za-z0-9+.-]*://")
LOOPBACK = frozenset(("localhost", "::1", "[::1]", "0:0:0:0:0:0:0:1", "[0:0:0:0:0:0:0:1]"))
LOOPBACK_V4 = re.compile(r"127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}")


def _command(words):
    """The words from the command's own name on, past its assignments and wrappers, as the header
    says: a word after a wrapper's option is its value unless it names a command read here."""
    i, n = 0, len(words)
    while i < n and ASSIGNMENT.match(words[i]):
        i += 1
    while i < n and os.path.basename(words[i]) in WRAPPERS:
        file_left, option = os.path.basename(words[i]) == "flock", False
        i += 1
        while i < n:
            word = words[i]
            if os.path.basename(word) in TOOLS | WRAPPERS:
                break
            if word.startswith("-") and word != "-":
                option = True
            elif ASSIGNMENT.match(word) or NUMBER.fullmatch(word):
                option = False
            elif option:
                option = False
            elif file_left:
                file_left = False
            else:
                break
            i += 1
    return words[i:]


def _short(word, value_flags):
    """A cluster of short options read as getopt reads it: its flags up to the first that takes a
    value, that flag or None, and the value joined to it ("" when it is the next word)."""
    for k, flag in enumerate(word[1:], 1):
        if flag in value_flags:
            return word[1:k], flag, word[k + 1 :]
    return word[1:], None, ""


def _curl(args):
    """Whether curl's arguments send a body or a file, and its URLs."""
    uploads, urls, k = False, [], 0
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
        elif word.startswith("-") and word != "-":
            flags, flag, joined = _short(word, CURL_VALUE_SHORT)
            uploads = uploads or bool(set(flags + (flag or "")) & CURL_UPLOAD_SHORT)
            k += bool(flag) and not joined
        elif word != "-":
            urls.append(word)
    return uploads, urls


def _wget_long(name):
    """The wget long options name stands for, as getopt takes it: itself, or those it is a prefix of."""
    if name in WGET_LONG:
        return {name}
    return {option for option in WGET_LONG if option.startswith(name)} if name else set()


def _wget(args):
    """Whether wget's arguments send a body, and its URLs."""
    uploads, urls, k = False, [], 0
    while k < len(args):
        word = args[k]
        k += 1
        if word == "--":
            urls += args[k:]
            break
        if word.startswith("--"):
            name, eq, value = word[2:].partition("=")
            options = _wget_long(name)
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
            uploads = uploads or bool(WGET_UPLOAD_COMMAND.match(re.sub(r"[-_]", "", value.lower()).lstrip()))
    return uploads, urls


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


def _host(url):
    """The lowercased host of a URL, as the header says."""
    authority = re.split(r"[/?#]", SCHEME.sub("", url, count=1), maxsplit=1)[0].rpartition("@")[2].lower()
    if authority in LOOPBACK:
        return authority
    if authority.startswith("["):
        close = authority.find("]")
        return authority[: close + 1] if close >= 0 else authority
    return authority.rpartition(":")[0] if ":" in authority else authority


def _outside(url):
    """Whether a URL is a literal whose host is outside the team's own."""
    if "$" in url or "`" in url or url.startswith(("<(", ">(")):
        return False
    host = _host(url)
    return not (host in LOOPBACK or LOOPBACK_V4.fullmatch(host))


def outbound_upload(command: str) -> str | None:
    """The reason the command uploads to a host outside the team's own, or None when it does not."""
    for words in simple_commands(command):
        words = _command(words)
        if not words:
            continue
        name, args = os.path.basename(words[0]), words[1:]
        if name in ("curl", "wget"):
            uploads, urls = (_curl if name == "curl" else _wget)(args)
            if uploads and any(_outside(url) for url in urls):
                return REASON
        elif name in SHELLS:
            script = _shell_string(args)
            if script is not None and outbound_upload(script):
                return REASON
        elif name == "eval" and outbound_upload(" ".join(args)):
            return REASON
    return None


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
