#!/usr/bin/env python3
"""Whether a Bash command's curl or wget uploads to a host outside the team's own.

Usage: python3 -I outbound.py   (the command on stdin; prints the reason when it uploads)

bin/lib/command_rules.py's upload row decides each command of a Bash call with _uploads, and
bin/hooks/command-guard refuses the call with REASON; so every role whose settings layer on
settings/worker.json gets the refusal, ops among them. Run as a file, it reads a command's text
on stdin and prints the reason when it uploads; it exits 0 either way, and input that is not
UTF-8, or an error of its own, exits 1 naming it on stderr. An error in the upload row refuses
the call too: a guard that cannot decide refuses.
It decides each simple command the command runs, as command_text.commands walks it (its header
says which wrappers and command strings that walk passes into: a shell's -c, eval, su's and
script's -c, env -S, flock -c, what watch and parallel join, find -exec), by the command's name,
its basename, with the assignments before it, env's among them; a script file a shell runs, or
one source or . reads, is a file's name, never read:
  - curl uploads with a request body or a file: -d, --data, --data-ascii, --data-binary,
    --data-urlencode, --data-raw, -F, --form, --form-string, --json, -T or --upload-file, each
    also as --expand-<flag>, a short one alone or in a cluster (-sSd@f), a long one as --flag
    value or --flag=value, whether its value is literal or an @file;
  - wget uploads with --post-data, --post-file, --body-data or --body-file, or a long option
    getopt takes as an abbreviation of one, or one of those set by -e or --execute (post_file=f).
A -c string behind another command (docker exec web sh -c '...') is read on the code text, which
adds it as a line of its own.
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
script file a shell runs, ssh itself, what command_text.commands does not walk (its header lists
it, ssh's remote command among it), another tool's upload and an interpreter's own request go
unseen, held by auto mode and the role's rule against reaching a refused thing another way.
"""

import os
import re
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from command_text import (  # noqa: E402
    SCHEME, SCRIPT, SOURCE, Command, _long_options, _short, commands,
)

REASON = "an upload to a host outside the team's own; a file's contents never go to an outside host"

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
LOOPBACK = frozenset(
    ("localhost", "::1", "[::1]", "0:0:0:0:0:0:0:1", "[0:0:0:0:0:0:0:1]", "0.0.0.0", "::", "[::]")
)
LOOPBACK_V4 = re.compile(r"127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}")


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


def _uploads(command: Command) -> bool:
    """Whether one Command of the walk uploads to a host outside the team's own: a curl or wget
    reached any way but as a script file or a sourced one, whose words are a file's name."""
    if command.reached in (SCRIPT, SOURCE) or not command.words:
        return False
    name, args = os.path.basename(command.words[0]), list(command.words[1:])
    if name not in ("curl", "wget"):
        return False
    uploads, urls, via = (_curl if name == "curl" else _wget)(args)
    via += [word.partition("=")[2] for word in command.assignments if PROXY_ASSIGNMENT.match(word)]
    return uploads and any(_outside(url) for url in urls + via)


def outbound_upload(command: str) -> str | None:
    """The reason the command uploads to a host outside the team's own, or None when it does not."""
    return REASON if any(_uploads(found) for found in commands(command)) else None


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
