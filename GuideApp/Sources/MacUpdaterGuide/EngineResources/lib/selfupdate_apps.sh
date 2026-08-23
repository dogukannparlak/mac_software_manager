# ------------------------------------------------------------------------------
# SPARKLE APPCAST DETECTION
# ------------------------------------------------------------------------------
# Apps that neither Homebrew nor the App Store manage usually ship Sparkle, the
# de-facto macOS updater framework. Their Info.plist points at an "appcast" RSS
# feed listing available builds.
#
# This DETECTS and REPORTS only - nothing is downloaded or installed.
#
# Two things real feeds get wrong if handled naively, both verified against
# live data:
#   1. Items are not sorted. AppCleaner's feed lists 3.4 before 3.6, so
#      "take the first item" reports an ancient version as the newest.
#   2. The first item is often a beta. DockDoor's newest entry carries
#      <sparkle:channel>beta</sparkle:channel>; following it would silently move
#      the user onto a prerelease channel.
# So every item is parsed, prereleases are dropped, and the maximum remains.

# Read one Info.plist key, tolerating apps whose plist is binary or unreadable
plist_value() {
    local plist="$1"
    local key="$2"
    [[ -f "$plist" ]] || return 1
    defaults read "$plist" "$key" 2>/dev/null
}

# The appcast URL for an app bundle.
# Falls back to the user defaults domain, because some apps (AltTab among them)
# set SUFeedURL at runtime instead of shipping it in Info.plist.
sparkle_feed_url() {
    local app_path="$1"
    local plist="$app_path/Contents/Info.plist"
    local feed="" bundle_id=""

    feed=$(plist_value "$plist" "SUFeedURL") || feed=""
    if [[ -z "$feed" ]]; then
        bundle_id=$(plist_value "$plist" "CFBundleIdentifier") || bundle_id=""
        if [[ -n "$bundle_id" ]]; then
            feed=$(defaults read "$bundle_id" SUFeedURL 2>/dev/null) || feed=""
        fi
    fi

    # Only https feeds are followed
    [[ "$feed" == https://* ]] || return 1
    print -r -- "$feed"
}

# Flatten an appcast into one line per item:
#   elemShort|attrShort|elemVersion|attrVersion|channel|url|edSignature|title
# xsltproc ships with macOS and handles the sparkle: namespace properly, which
# regex over XML does not.
SPARKLE_XSLT='<?xml version="1.0"?>
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
<xsl:output method="text"/>
<xsl:template match="/">
<xsl:for-each select="//*[local-name()=&apos;item&apos;]">
<xsl:value-of select="translate(normalize-space(*[local-name()=&apos;shortVersionString&apos;]),&apos;|&apos;,&apos;/&apos;)"/><xsl:text>|</xsl:text>
<xsl:value-of select="translate(normalize-space(*[local-name()=&apos;enclosure&apos;]/@*[local-name()=&apos;shortVersionString&apos;]),&apos;|&apos;,&apos;/&apos;)"/><xsl:text>|</xsl:text>
<xsl:value-of select="translate(normalize-space(*[local-name()=&apos;version&apos;]),&apos;|&apos;,&apos;/&apos;)"/><xsl:text>|</xsl:text>
<xsl:value-of select="translate(normalize-space(*[local-name()=&apos;enclosure&apos;]/@*[local-name()=&apos;version&apos;]),&apos;|&apos;,&apos;/&apos;)"/><xsl:text>|</xsl:text>
<xsl:value-of select="translate(normalize-space(*[local-name()=&apos;channel&apos;]),&apos;|&apos;,&apos;/&apos;)"/><xsl:text>|</xsl:text>
<xsl:value-of select="translate(normalize-space(*[local-name()=&apos;enclosure&apos;]/@url),&apos;|&apos;,&apos;/&apos;)"/><xsl:text>|</xsl:text>
<xsl:value-of select="translate(normalize-space(*[local-name()=&apos;enclosure&apos;]/@*[local-name()=&apos;edSignature&apos;]),&apos;|&apos;,&apos;/&apos;)"/><xsl:text>|</xsl:text>
<xsl:value-of select="translate(normalize-space(*[local-name()=&apos;title&apos;]),&apos;|&apos;,&apos;/&apos;)"/>
<xsl:text>&#10;</xsl:text>
</xsl:for-each>
</xsl:template>
</xsl:stylesheet>'

# Best stable release in an appcast.
# Prints "version|url|edSignature", or nothing when the feed has no usable
# stable entry.
sparkle_best_release() {
    local feed_url="$1"
    local xml_file xsl_file line
    local elem_short attr_short elem_ver attr_ver channel url edsig title
    local candidate best_version="" best_url="" best_sig=""

    xml_file="$(mktemp "${TMPDIR:-/tmp}/appcast.XXXXXX")" || return 1
    xsl_file="$(mktemp "${TMPDIR:-/tmp}/appcast_xsl.XXXXXX")" || { rm -f "$xml_file"; return 1; }

    print -r -- "$SPARKLE_XSLT" > "$xsl_file"

    if ! curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 5 --max-time 20 \
        -H "User-Agent: $USER_AGENT" "$feed_url" -o "$xml_file" 2>/dev/null; then
        rm -f "$xml_file" "$xsl_file"
        return 1
    fi

    for line in "${(@f)$(xsltproc "$xsl_file" "$xml_file" 2>/dev/null)}"; do
        [[ -n "$line" ]] || continue
        IFS='|' read -r elem_short attr_short elem_ver attr_ver channel url edsig title <<< "$line"

        # A named channel means anything other than the default stable one
        [[ -n "$channel" ]] && continue

        # Prefer the human version; fall back to the build number
        candidate="${elem_short:-$attr_short}"
        [[ -z "$candidate" ]] && candidate="${elem_ver:-$attr_ver}"
        [[ -z "$candidate" ]] && candidate="$title"

        # Drop prereleases however they are labelled
        is_prerelease_version "$candidate" && continue
        is_prerelease_version "$title" && continue

        candidate=$(normalize_version "$candidate") || continue

        if [[ -z "$best_version" ]] || ! is-at-least "$candidate" "$best_version"; then
            best_version="$candidate"
            best_url="$url"
            best_sig="$edsig"
        fi
    done

    rm -f "$xml_file" "$xsl_file"

    [[ -n "$best_version" ]] || return 1
    print -r -- "${best_version}|${best_url}|${best_sig}"
}

# Cask tokens plausibly matching an app name, used to skip Homebrew-managed
# apps.
#
# Deliberately narrower than the matching in setup_mac.sh: that one runs
# interactively and the user confirms the result, while this one silently hides
# an app from the menu. Progressive truncation ("alt-tab" -> "alt") is therefore
# left out - a wrong match here means an update is never reported at all.
app_cask_candidates() {
    local app_name="$1"
    local base="" camel=""
    typeset -a out

    base=$(print -r -- "$app_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    camel=$(print -r -- "$app_name" \
        | sed -E 's/([a-z0-9])([A-Z])/\1-\2/g; s/([A-Z]+)([A-Z][a-z])/\1-\2/g' \
        | tr '[:upper:]' '[:lower:]' | tr ' ' '-')

    out=("$base")
    [[ -n "$camel" && "$camel" != "$base" ]] && out+=("$camel")
    out+=("${base//./}")
    [[ -n "$camel" ]] && out+=("${camel//./}")

    print -rl -- "${(@u)out}"
}

# Is this app already managed by a Homebrew cask?
# Reported Sparkle updates for cask apps would contradict the Homebrew section
# and, if acted on, desynchronise brew's metadata.
app_is_brew_managed() {
    local app_name="$1"
    local candidate

    (( ${#INSTALLED_CASK_TOKENS} > 0 )) || return 1

    for candidate in "${(@f)$(app_cask_candidates "$app_name")}"; do
        [[ -n "$candidate" ]] || continue
        [[ -n "${INSTALLED_CASK_TOKENS[$candidate]}" ]] && return 0
    done

    return 1
}

# ------------------------------------------------------------------------------
# GITHUB RELEASES
# ------------------------------------------------------------------------------
# releases.atom instead of api.github.com: the API allows 60 unauthenticated
# requests per hour, which a scan of /Applications burns through immediately.
# The atom feed has no such limit and needs no token.

# Flatten releases.atom into "tag|title" per entry.
# The tag comes from <id> (".../Repository/<n>/<tag>"), which is stable; the
# title is free-form release naming and is only used to spot prereleases.
GITHUB_ATOM_XSLT='<?xml version="1.0"?>
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
<xsl:output method="text"/>
<xsl:template match="/">
<xsl:for-each select="//*[local-name()=&apos;entry&apos;]">
<xsl:value-of select="translate(normalize-space(*[local-name()=&apos;id&apos;]),&apos;|&apos;,&apos;/&apos;)"/><xsl:text>|</xsl:text>
<xsl:value-of select="translate(normalize-space(*[local-name()=&apos;title&apos;]),&apos;|&apos;,&apos;/&apos;)"/>
<xsl:text>&#10;</xsl:text>
</xsl:for-each>
</xsl:template>
</xsl:stylesheet>'

# Newest stable release of a GitHub repository.
# Prints "version|release_page_url", or nothing when there is no usable release.
github_best_release() {
    local repo="$1"
    local atom_file xsl_file line entry_id title tag candidate
    local best_version="" best_tag=""

    [[ "$repo" == */* ]] || return 1

    atom_file="$(mktemp "${TMPDIR:-/tmp}/releases.XXXXXX")" || return 1
    xsl_file="$(mktemp "${TMPDIR:-/tmp}/releases_xsl.XXXXXX")" || { rm -f "$atom_file"; return 1; }

    print -r -- "$GITHUB_ATOM_XSLT" > "$xsl_file"

    if ! curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 5 --max-time 20 \
        -H "User-Agent: $USER_AGENT" "https://github.com/${repo}/releases.atom" \
        -o "$atom_file" 2>/dev/null; then
        rm -f "$atom_file" "$xsl_file"
        return 1
    fi

    for line in "${(@f)$(xsltproc "$xsl_file" "$atom_file" 2>/dev/null)}"; do
        [[ -n "$line" ]] || continue
        entry_id="${line%%|*}"
        title="${line#*|}"
        tag="${entry_id##*/}"

        [[ -n "$tag" ]] || continue

        # releases.atom does not flag prereleases, so tag and title text is all
        # there is to go on. Anything that names itself a prerelease is dropped.
        is_prerelease_version "$tag" && continue
        is_prerelease_version "$title" && continue

        candidate=$(normalize_version "$tag") || continue

        if [[ -z "$best_version" ]] || ! is-at-least "$candidate" "$best_version"; then
            best_version="$candidate"
            best_tag="$tag"
        fi
    done

    rm -f "$atom_file" "$xsl_file"

    [[ -n "$best_version" ]] || return 1
    print -r -- "${best_version}|https://github.com/${repo}/releases/tag/${best_tag}"
}

# Derive "owner/repo" for an app, in decreasing order of confidence:
#   1. a GitHub host in the Sparkle feed URL (the feed is served by that repo)
#   2. a com.github.<owner>.<repo> bundle identifier
# Anything less certain is left to tracked_apps.conf rather than guessed.
github_repo_for_app() {
    local app_path="$1"
    local feed="" bundle_id="" owner="" repo=""

    feed=$(sparkle_feed_url "$app_path" 2>/dev/null) || feed=""
    if [[ -n "$feed" ]]; then
        case "$feed" in
            https://raw.githubusercontent.com/*|https://github.com/*|https://*.github.io/*)
                if [[ "$feed" == https://*.github.io/* ]]; then
                    # https://owner.github.io/Repo/appcast.xml
                    owner="${${feed#https://}%%.github.io/*}"
                    repo="${${feed#https://*.github.io/}%%/*}"
                else
                    owner="${${feed#https://*/}%%/*}"
                    repo="${${feed#https://*/${owner}/}%%/*}"
                fi
                if [[ -n "$owner" && -n "$repo" ]]; then
                    print -r -- "${owner}/${repo}"
                    return 0
                fi
                ;;
        esac
    fi

    bundle_id=$(plist_value "$app_path/Contents/Info.plist" CFBundleIdentifier) || bundle_id=""
    if [[ "$bundle_id" == com.github.*.* ]]; then
        owner="${${bundle_id#com.github.}%%.*}"
        repo="${${bundle_id#com.github.${owner}.}%%.*}"
        if [[ -n "$owner" && -n "$repo" ]]; then
            print -r -- "${owner}/${repo}"
            return 0
        fi
    fi

    return 1
}

# ------------------------------------------------------------------------------
# OFFICIAL WEBSITES & GITHUB REPOSITORIES
# ------------------------------------------------------------------------------
# Where these come from, entirely from data already sitting on disk or given by
# an authoritative API - no guessing, no per-app LLM call:
#   - Homepage: 'homepage' is a mandatory field in every Homebrew cask
#     definition, so 'brew info --cask --json=v2' gives it for free, from the
#     local tap. For non-cask apps, the GitHub API's own 'homepage' field on
#     the repo (see below), cached for a day since it never changes.
#   - GitHub repo: a cask's *download URL* is frequently a GitHub release
#     asset (https://github.com/owner/repo/releases/download/...) - that is
#     exactly where the installed copy came from, not an inference. For
#     non-cask apps, the same Sparkle-feed / bundle-id derivation used for
#     self-update checking.
# An app with neither simply has no entry - "if it's known", not "always".

# Owner/repo when a cask's download URL is a GitHub release asset - which it
# is for most indie Mac apps, since that is where `brew audit` steers cask
# authors. This is exact, not a guess: it is literally where the running copy
# was downloaded from.
cask_repo_from_url() {
    local url="$1"
    [[ "$url" == https://github.com/*/*/releases/* ]] || return 1

    local rest="${url#https://github.com/}"
    local owner="${rest%%/*}"
    rest="${rest#*/}"
    local repo="${rest%%/*}"

    [[ -n "$owner" && -n "$repo" ]] || return 1
    print -r -- "${owner}/${repo}"
}

# Homepage and (when derivable) GitHub repo for every installed cask, from a
# single 'brew info' call. Emits: token|homepage|repo
# 'repo' is blank when the cask does not download from GitHub releases (its own
# CDN, SourceForge, a JetBrains/Microsoft/etc. server) - nothing is guessed at.
collect_cask_homepages() {
    typeset -a casks
    casks=("${(@f)$(brew list --cask 2>/dev/null)}")
    (( ${#casks[@]} > 0 )) || return 0

    local json_file
    json_file="$(mktemp "${TMPDIR:-/tmp}/cask_homepages.XXXXXX")" || return 1

    if ! brew info --cask --json=v2 "${casks[@]}" > "$json_file" 2>/dev/null; then
        rm -f "$json_file"
        return 1
    fi

    local count idx token homepage download_url repo result=""
    count=$(plutil -extract casks raw -o - "$json_file" 2>/dev/null)
    if [[ ! "$count" =~ ^[0-9]+$ ]]; then
        rm -f "$json_file"
        return 1
    fi

    for (( idx = 0; idx < count; idx++ )); do
        token=$(plutil -extract "casks.${idx}.token" raw -o - "$json_file" 2>/dev/null) || continue
        [[ -n "$token" ]] || continue

        homepage=$(plutil -extract "casks.${idx}.homepage" raw -o - "$json_file" 2>/dev/null) || homepage=""
        [[ "$homepage" == https://* ]] || homepage=""

        download_url=$(plutil -extract "casks.${idx}.url" raw -o - "$json_file" 2>/dev/null) || download_url=""
        repo=$(cask_repo_from_url "$download_url") || repo=""

        result+="${token}|${homepage}|${repo}"$'\n'
    done

    rm -f "$json_file"
    print -rn -- "$result"
}

# The 'homepage' field on a GitHub repository, when the repo (and GitHub) says
# there is one. Empty result is normal, not an error - most repos leave it blank.
github_repo_homepage() {
    local repo="$1"
    local json homepage

    json=$(curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 5 --max-time 10 \
        -H "User-Agent: $USER_AGENT" "https://api.github.com/repos/${repo}" 2>/dev/null) || return 1

    homepage=$(print -r -- "$json" | plutil -extract homepage raw -o - - 2>/dev/null) || return 1
    [[ "$homepage" == https://* ]] || return 1
    print -r -- "$homepage"
}

# Homepage for every installed app whose GitHub repo could be derived and is
# not already covered by a cask homepage. Emits: AppName|homepage
collect_github_homepages() {
    local app_path app_name repo homepage cask_line
    local result=""

    typeset -gA INSTALLED_CASK_TOKENS
    INSTALLED_CASK_TOKENS=()
    for cask_line in "${(@f)$(cache_get "brew_casks")}"; do
        [[ -n "$cask_line" ]] && INSTALLED_CASK_TOKENS[${cask_line%% *}]=1
    done

    for app_path in /Applications/*.app(N) /Applications/*/*.app(N); do
        app_name="${${app_path:t}%.app}"

        [[ "$app_path" == /Applications/Setapp/* ]] && continue
        [[ -d "$app_path/Contents/_MASReceipt" ]] && continue
        app_is_brew_managed "$app_name" && continue

        repo=$(github_repo_for_app "$app_path") || continue
        homepage=$(github_repo_homepage "$repo") || continue

        result+="${app_name}|${homepage}"$'\n'
    done

    print -rn -- "$result"
}

# ------------------------------------------------------------------------------
# TRACKED APPS
# ------------------------------------------------------------------------------
# User-editable overrides for how an app is checked:
#   AppName|method|identifier
# method: sparkle (identifier = appcast URL)
#         github  (identifier = owner/repo)
#         homebrew(identifier = cask token; the Homebrew section owns it)
#         skip    (never check this app)
# Automatic detection only applies to apps with no entry here.
tracked_app_entry() {
    local app_name="$1"
    local entry_name entry_method entry_id

    [[ -f "$TRACKED_APPS_FILE" ]] || return 1

    while IFS='|' read -r entry_name entry_method entry_id || [[ -n "$entry_name" ]]; do
        entry_name="${entry_name#"${entry_name%%[![:space:]]*}"}"
        entry_name="${entry_name%"${entry_name##*[![:space:]]}"}"
        [[ -z "$entry_name" || "$entry_name" == \#* ]] && continue

        entry_method="${entry_method#"${entry_method%%[![:space:]]*}"}"
        entry_method="${entry_method%"${entry_method##*[![:space:]]}"}"
        entry_id="${entry_id#"${entry_id%%[![:space:]]*}"}"
        entry_id="${entry_id%"${entry_id##*[![:space:]]}"}"

        if [[ "${entry_name:l}" == "${app_name:l}" ]]; then
            print -r -- "${entry_method:l}|${entry_id}"
            return 0
        fi
    done < "$TRACKED_APPS_FILE"

    return 1
}

# Create the file with instructions on first use, never overwrite it
ensure_tracked_apps_file() {
    [[ -f "$TRACKED_APPS_FILE" ]] && return 0

    cat > "$TRACKED_APPS_FILE" << 'EOF'
# How to check individual applications for updates.
#
# One entry per line:   App Name|method|identifier
#   sparkle  | identifier = appcast URL          e.g. MyApp|sparkle|https://example.com/appcast.xml
#   github   | identifier = owner/repo           e.g. MyApp|github|owner/MyApp
#   homebrew | identifier = cask token           e.g. MyApp|homebrew|my-app
#   skip     | identifier unused                 e.g. MyApp|skip|
#
# "App Name" is the bundle name without ".app", matched case insensitively.
# Apps without an entry here are detected automatically: a Sparkle feed in
# Info.plist, otherwise a GitHub repository derived from that feed or from a
# com.github.owner.repo bundle identifier.
#
# Homebrew casks and App Store apps are already covered by their own sections
# and are skipped automatically - add a "skip" entry only to silence something.
EOF
    chmod 600 "$TRACKED_APPS_FILE" 2>/dev/null || true
}

# Scan /Applications for apps that update themselves, and report newer stable
# releases. Detection only: nothing is downloaded or installed.
# Emits: method|AppName|localVersion|remoteVersion|url|signature
collect_app_updates() {
    local app_path app_name feed release remote_ver local_ver url edsig repo
    local tracked tracked_method tracked_id method
    local result=""
    local cask_line=""

    ensure_tracked_apps_file

    # Installed cask tokens, for the "managed elsewhere" check
    typeset -gA INSTALLED_CASK_TOKENS
    INSTALLED_CASK_TOKENS=()
    for cask_line in "${(@f)$(cache_get "brew_casks")}"; do
        [[ -n "$cask_line" ]] && INSTALLED_CASK_TOKENS[${cask_line%% *}]=1
    done

    for app_path in /Applications/*.app(N) /Applications/*/*.app(N); do
        app_name="${${app_path:t}%.app}"
        method=""
        feed=""
        repo=""

        # Setapp manages its own catalogue; touching those apps breaks it
        [[ "$app_path" == /Applications/Setapp/* ]] && continue

        # App Store apps are covered by the mas section
        [[ -d "$app_path/Contents/_MASReceipt" ]] && continue

        # Respect the ignore list (keyed by app name for this source)
        is_ignored "sparkle" "$app_name" && continue

        local_ver=$(plist_value "$app_path/Contents/Info.plist" CFBundleShortVersionString) || continue
        local_ver=$(normalize_version "$local_ver") || continue

        # An explicit entry always wins over detection
        if tracked=$(tracked_app_entry "$app_name"); then
            tracked_method="${tracked%%|*}"
            tracked_id="${tracked#*|}"

            case "$tracked_method" in
                "skip"|"homebrew") continue ;;
                "sparkle")
                    [[ -n "$tracked_id" ]] || continue
                    method="sparkle"
                    feed="$tracked_id"
                    ;;
                "github")
                    [[ -n "$tracked_id" ]] || continue
                    method="github"
                    repo="$tracked_id"
                    ;;
                *) continue ;;
            esac
        else
            # Homebrew casks are covered by the Homebrew section
            app_is_brew_managed "$app_name" && continue

            if feed=$(sparkle_feed_url "$app_path"); then
                method="sparkle"
            elif repo=$(github_repo_for_app "$app_path"); then
                method="github"
            else
                continue
            fi
        fi

        if [[ "$method" == "sparkle" ]]; then
            release=$(sparkle_best_release "$feed") || continue
            remote_ver="${release%%|*}"
            url="${${release#*|}%|*}"
            edsig="${release##*|}"
        else
            release=$(github_best_release "$repo") || continue
            remote_ver="${release%%|*}"
            url="${release#*|}"
            edsig=""
        fi

        # Only report a genuine forward step
        [[ -n "$remote_ver" ]] || continue
        is-at-least "$remote_ver" "$local_ver" && continue

        result+="${method}|${app_name}|${local_ver}|${remote_ver}|${url}|${edsig}"$'\n'
    done

    print -rn -- "$result"
}
