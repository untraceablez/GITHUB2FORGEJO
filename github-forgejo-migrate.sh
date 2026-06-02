#!/bin/bash
# This script migrates a GitHub user's repositories to a Forgejo instance.
# It requires curl and jq to be installed.
# Environment variables (if not provided, you will be prompted):
#   GITHUB_USER: The GitHub username.
#   GITHUB_IS_ORG: Whether the GitHub user is an organization (Yes/No).
#   GITHUB_TOKEN: An access token for private GitHub repositories (optional).
#   FORGEJO_URL: The Forgejo instance URL (include the protocol, e.g. https://forgejo.example.com).
#   FORGEJO_USER: The Forgejo user/organization to migrate to.
#   FORGEJO_TOKEN: A Forgejo access token.
#   STRATEGY: Either "mirror" or "clone". "mirrored" will create a mirror (which Forgejo will update periodically),
#             "clone" will only clone once.
#   FORCE_SYNC: Whether to delete repositories on Forgejo that no longer exist on GitHub.
#              Answer Yes (to delete) or No.
#   OVERWRITES: How to reconcile per-file differences when a repo already exists on Forgejo
#              (only applies to the "clone" strategy; mirrors are read-only via the API).
#              YES => GitHub files overwrite the existing Forgejo files.
#              NO  => differing GitHub files are added alongside as <name>_copy.<ext>.
#              If unset and no .env is present you will be prompted; an empty answer defaults to NO.

# Determine the current directory of the script. Location of .env file defaults to being co-located with the script. 
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
else
    echo "[Info] No .env file found at $ENV_FILE. Proceeding to manual setup. You will be prompted for environment variables..."
fi

# Define some color codes for output.
red=$(tput setaf 1)
green=$(tput setaf 2)
yellow=$(tput setaf 3)
blue=$(tput setaf 4)
cyan=$(tput setaf 6)
purple=$(tput setaf 5)
white=$(tput setaf 7)
reset=$(tput sgr0)

# Additional check to verify commands are installed as described in the documentation.
command_exists() {
	if command -v "$1" >/dev/null 2>&1; then
		printf "%sChecking Prerequisite: %s is: Installed!\n" "$green" "$1"
	else
		printf "${yellow}%b$1 is not installed...%b\n"
		exit 1
	fi
}

# Function: Wraps curl to validate exit code and non-empty response.
# Parameters:
#   $@ - All arguments are passed to curl
# Output: curl stdout (response body)
# Returns 0 on success (prints response to stdout), 1 on failure. Caller prints error message.
safe_curl() {
	local response
	local curl_exit_code

	response=$(curl -sS "$@")
	curl_exit_code=$?

	if [ $curl_exit_code -ne 0 ]; then
		return 1
	fi

	if [ -z "$response" ]; then
		return 1
	fi

	echo "$response"
}

command_exists bash
command_exists curl
command_exists jq

# Function: if the passed variable is empty, prompt the user.
# The function trims white space from the input.
# Two display strings are provided:
#   prompt_msg: The prompt to display (this can include color codes)
#   default_value: A plain default value that will be used if the user enters nothing.
#   is_secret: (Optional) If set to true/yes, the input will be hidden and the output masked.
or_default() {
	local current_val="$1"
	local prompt_msg="$2"
	local default_value="$3"
	local is_secret="$4"
	local input_val

	# Normalize is_secret
	if [[ "$is_secret" =~ ^[Yy] ]]; then
		is_secret=true
	else
		is_secret=false
	fi

	# If the variable is already set, notify the user and return that value.
	if [ -n "$current_val" ]; then
		local display_val="$current_val"
		if [ "$is_secret" = true ]; then
			if [ ${#current_val} -gt 5 ]; then
				display_val="...${current_val: -5}"
			else
				display_val="*****"
			fi
		fi
		printf "%b found in environment, using: %s%b\n" "${cyan}${prompt_msg}" "$display_val" "${reset}" >&2
		echo "$current_val"
		return
	fi

	# Prompt the user.
	if [ "$is_secret" = true ]; then
		# Silent input for secrets
		printf "%s " "$prompt_msg" >&2
		read -r -s input_val
		echo "" >&2 # Newline after silent input
	else
		read -r -p "$prompt_msg " input_val
	fi

	# Trim any extraneous whitespace.
	input_val="$(echo "$input_val" | xargs)"

	if [ -z "$input_val" ] && [ -n "$default_value" ]; then
		input_val="$default_value"
		local display_default="$default_value"
		if [ "$is_secret" = true ]; then
			if [ ${#default_value} -gt 5 ]; then
				display_default="...${default_value: -5}"
			else
				display_default="*****"
			fi
		fi
		printf "%bNo input provided. Using default: %s%b\n" "${cyan}" "$display_default" "${reset}" >&2
	fi

	echo "$input_val"
}

# Get configuration from the environment or via prompt.
GITHUB_USER=$(or_default "$GITHUB_USER" "${red}GitHub username:${reset}" "")
if [ -z "$GITHUB_USER" ]; then
	echo -e "${red}Error: GITHUB_USER is required.${reset}" >&2
	exit 1
fi

# Auto-detect GITHUB_IS_ORG if not provided
if [ -z "$GITHUB_IS_ORG" ]; then
	echo -ne "${cyan}Checking account type for $GITHUB_USER...${reset}"
	# Use token if available to avoid rate limits
	curl_args=()
	if [ -n "$GITHUB_TOKEN" ]; then
		curl_args+=(-H "Authorization: token $GITHUB_TOKEN")
	fi

	api_response=$(safe_curl "${curl_args[@]}" "https://api.github.com/users/$GITHUB_USER") || {
		echo -e " ${red}Failed to reach GitHub API. Check network connectivity.${reset}" >&2
		exit 1
	}
	account_type=$(echo "$api_response" | jq -r '.type')

	if [[ "$account_type" == "Organization" ]]; then
		GITHUB_IS_ORG=true
		echo -e " ${green}Organization detected.${reset}"
	else
		GITHUB_IS_ORG=false
		echo -e " ${green}User detected.${reset}"
	fi
else
	printf "%b found in environment, using: %s%b\n" "${cyan}Is the GitHub user an organization? (Yes/No):${reset}" "$GITHUB_IS_ORG" "${reset}" >&2
	# Clean up user input if provided manually
	GITHUB_IS_ORG="$(echo "$GITHUB_IS_ORG" | tr -d '\n' | tr '[:upper:]' '[:lower:]')"
	if [[ "$GITHUB_IS_ORG" =~ ^y(es)?$ ]] || [[ "$GITHUB_IS_ORG" == "true" ]]; then
		GITHUB_IS_ORG=true
	else
		GITHUB_IS_ORG=false
	fi
fi

GITHUB_TOKEN=$(or_default "$GITHUB_TOKEN" "${red}GitHub access token (optional, only used for private repositories):${reset}" "" "yes")
FORGEJO_URL=$(or_default "$FORGEJO_URL" "${green}Forgejo instance URL (with https://):${reset}" "")
# Remove any trailing slash.
FORGEJO_URL="${FORGEJO_URL%/}"
FORGEJO_USER=$(or_default "$FORGEJO_USER" "${green}Forgejo username or organization to migrate to:${reset}" "")
FORGEJO_TOKEN=$(or_default "$FORGEJO_TOKEN" "${green}Forgejo access token:${reset}" "" "yes")
STRATEGY=$(or_default "$STRATEGY" "${cyan}Strategy (mirror/clone):${reset}" "mirror")

# Convert STRATEGY to lowercase so input variations are handled.
STRATEGY="$(echo "$STRATEGY" | tr -d '\n' | tr '[:upper:]' '[:lower:]')"

# Validate STRATEGY input.
if [[ "$STRATEGY" != "mirror" && "$STRATEGY" != "clone" ]]; then
	echo -e "${red}Error: Strategy must be either 'mirror' or 'clone'.${reset}" >&2
	exit 1
fi
# Get the FORCE_SYNC setting from the environment or via prompt.
FORCE_SYNC=$(or_default "$FORCE_SYNC" "${yellow}Should mirrored repos that don't have a GitHub source anymore be deleted? (Yes/No):${reset}" "No")

# Clean up FORCE_SYNC input by removing newlines and converting to lowercase.
FORCE_SYNC="$(echo "$FORCE_SYNC" | tr -d '\n' | tr '[:upper:]' '[:lower:]')"

# Convert response to a boolean: true if the answer is yes (starting with "y"), false otherwise.
if [[ "$FORCE_SYNC" =~ ^y(es)?$ ]]; then
	FORCE_SYNC=true
else
	FORCE_SYNC=false
fi

# Get the MIGRATE_ARCHIVE_STATUS setting from the environment or via prompt.
MIGRATE_ARCHIVE_STATUS=$(or_default "$MIGRATE_ARCHIVE_STATUS" "${yellow}Should the archive status of repositories be transferred? (Yes/No):${reset}" "Yes")

# Clean up MIGRATE_ARCHIVE_STATUS input.
MIGRATE_ARCHIVE_STATUS="$(echo "$MIGRATE_ARCHIVE_STATUS" | tr -d '\n' | tr '[:upper:]' '[:lower:]')"

if [[ "$MIGRATE_ARCHIVE_STATUS" =~ ^y(es)?$ ]]; then
	MIGRATE_ARCHIVE_STATUS=true
else
	MIGRATE_ARCHIVE_STATUS=false
fi

# Get the MIGRATE_FORKS setting from the environment or via prompt.
MIGRATE_FORKS=$(or_default "$MIGRATE_FORKS" "${yellow}Should fork repositories be migrated? (Yes/No):${reset}" "Yes")

# Clean up MIGRATE_FORKS input.
MIGRATE_FORKS="$(echo "$MIGRATE_FORKS" | tr -d '\n' | tr '[:upper:]' '[:lower:]')"

if [[ "$MIGRATE_FORKS" =~ ^y(es)?$ ]]; then
	MIGRATE_FORKS=true
else
	MIGRATE_FORKS=false
fi

# Get the DRY_RUN setting from the environment or via prompt.
DRY_RUN=$(or_default "$DRY_RUN" "${yellow}Preview actions without executing (dry run)? (Yes/No):${reset}" "No")

# Clean up DRY_RUN input.
DRY_RUN="$(echo "$DRY_RUN" | tr -d '\n' | tr '[:upper:]' '[:lower:]')"

if [[ "$DRY_RUN" =~ ^y(es)?$ ]]; then
	DRY_RUN=true
else
	DRY_RUN=false
fi

# Get the OVERWRITES setting from the environment or via prompt.
# Controls how differing files are reconciled during the clone-strategy file sync: YES => GitHub files overwrite the existing Forgejo files. NO  => differing GitHub files are added alongside as <name>_copy.<ext>. When no .env (or no OVERWRITES) is provided the user is prompted; an empty answer defaults to NO.
OVERWRITES=$(or_default "$OVERWRITES" "${yellow}When a file differs, overwrite the Forgejo file with GitHub's version? (YES/NO):${reset}" "No")

# Clean up OVERWRITES input.
OVERWRITES="$(echo "$OVERWRITES" | tr -d '\n' | tr '[:upper:]' '[:lower:]')"

if [[ "$OVERWRITES" =~ ^y(es)?$ ]]; then
	OVERWRITES=true
else
	OVERWRITES=false
fi

echo -e "${green}Force sync is set to: ${FORCE_SYNC}${reset}"
echo -e "${green}Migrate archive status is set to: ${MIGRATE_ARCHIVE_STATUS}${reset}"
echo -e "${green}Migrate forks is set to: ${MIGRATE_FORKS}${reset}"
echo -e "${green}Dry run is set to: ${DRY_RUN}${reset}"
echo -e "${green}Overwrite differing files is set to: ${OVERWRITES}${reset}"

if $DRY_RUN; then
	echo -e "${cyan}=== DRY RUN MODE ===${reset}"
	echo -e "${cyan}No changes will be made. Previewing actions only.${reset}"
fi

# -------------------------
# 1. Fetch GitHub Repositories via API (paginated)
# -------------------------
all_repos="[]" # will hold a JSON array of repos
page=1

# Determine API endpoint and headers once
repo_base_url="https://api.github.com/users/$GITHUB_USER/repos"
curl_opts=()

# Use authenticated user endpoint if token exists (and not overridden by Org)
if [ -n "$GITHUB_TOKEN" ]; then
	curl_opts+=(-H "Authorization: token $GITHUB_TOKEN")
	repo_base_url="https://api.github.com/user/repos"
fi

# If Organization, force Org endpoint
if $GITHUB_IS_ORG; then
	repo_base_url="https://api.github.com/orgs/$GITHUB_USER/repos"
fi

while true; do
	response=$(safe_curl "${curl_opts[@]}" "$repo_base_url?per_page=100&page=$page") || {
		echo -e "${red}Failed to fetch GitHub repositories. Check network connectivity.${reset}" >&2
		exit 1
	}

	# Check for API error messages
	if echo "$response" | jq -e 'if type == "object" and .message then true else false end' >/dev/null; then
		err_msg=$(echo "$response" | jq -r '.message')
		echo -e "${red}GitHub API Error: $err_msg${reset}" >&2
		exit 1
	fi

	# Get total count of repos returned by the API (before filtering).
	total_count=$(echo "$response" | jq 'if type == "array" then length else 0 end')

	# If the API returned no repos at all, we're done paginating.
	if [ "$total_count" -eq 0 ]; then
		break
	fi

	# Filter repos so that only those whose owner.login matches GITHUB_USER are selected.
	filtered=$(echo "$response" | jq --arg gu "$GITHUB_USER" 'if type == "array" then [.[] | select(.owner.login == $gu)] else [] end')
	filtered_count=$(echo "$filtered" | jq 'length')

	# Merge matching repos with the existing JSON array (if any matched).
	if [ "$filtered_count" -gt 0 ]; then
		all_repos=$(echo "$all_repos" "$filtered" | jq -s 'add')
	fi

	# If we received less than 100 repos from the API, we've reached the last page.
	if [ "$total_count" -lt 100 ]; then
		break
	fi
	page=$((page + 1))
done

# -------------------------
# 2. (Optional) Force sync: Delete Forgejo repos that are mirrored but no longer exist on GitHub.
# -------------------------
if $FORCE_SYNC; then
	# Get GitHub repo names into a plain list.
	github_repo_names=$(echo "$all_repos" | jq -r '.[].name')

	# Fetch Forgejo repos.
	forgejo_response=$(safe_curl -H "Authorization: token $FORGEJO_TOKEN" "$FORGEJO_URL/api/v1/user/repos") || {
		echo -e "${red}Failed to fetch Forgejo repositories. Check FORGEJO_URL and network connectivity.${reset}" >&2
		exit 1
	}

	# Filter to only those repos created via mirror; if no GitHub token provided, also filter out private repos.
	if [ -z "$GITHUB_TOKEN" ]; then
		forgejo_mirrored=$(echo "$forgejo_response" | jq '[.[] | select(.mirror == true and .private == false)]')
	else
		forgejo_mirrored=$(echo "$forgejo_response" | jq '[.[] | select(.mirror == true)]')
	fi

	count_forgejo=$(echo "$forgejo_mirrored" | jq 'length')
	if [ "$count_forgejo" -gt 0 ]; then
		# Iterate over each Forgejo mirrored repo.
		echo "$forgejo_mirrored" | jq -c '.[]' | while read -r repo; do
			repo_name=$(echo "$repo" | jq -r '.name')
			full_name=$(echo "$repo" | jq -r '.full_name')
			# If this repo name is not present in the GitHub repos list, delete it.
			if ! echo "$github_repo_names" | grep -Fxq "$repo_name"; then
				if ! $DRY_RUN; then
					echo -ne "${red}Deleting ${yellow}$FORGEJO_URL/$full_name${red} because the mirror source doesn't exist on GitHub anymore...${reset}"
					delete_response=$(curl -sS -w "%{http_code}" -o /dev/null -X DELETE -H "Authorization: token $FORGEJO_TOKEN" "$FORGEJO_URL/api/v1/repos/$full_name")
					delete_exit_code=$?
					if [ $delete_exit_code -ne 0 ]; then
						echo -e " ${red}Failed (network error, curl exit code $delete_exit_code).${reset}"
					elif [ "$delete_response" -ge 200 ] && [ "$delete_response" -lt 300 ]; then
						echo -e " ${green}Success!${reset}"
					else
						echo -e " ${red}Failed (HTTP $delete_response).${reset}"
					fi
				else
					echo -e "${cyan}[DRY RUN] Would delete: $FORGEJO_URL/$full_name${reset}"
				fi
			fi
		done
	fi
fi

# -------------------------
# File-level sync helpers.
#
# After a clone-strategy migration, GitHub and Forgejo are compared file-by-file
# (across every branch). Git blob SHAs are computed identically by GitHub and
# Forgejo, so two files are "the same" exactly when their blob SHAs match.
#   - A GitHub file with no Forgejo counterpart is created.
#   - A GitHub file whose SHA differs from Forgejo's is either overwritten
#     (OVERWRITES=true) or copied to <name>_copy.<ext> (OVERWRITES=false).
# Files that exist only on Forgejo are left untouched (repo-level deletions are
# handled separately by FORCE_SYNC).
#
# Mirror repos are intentionally skipped: Forgejo keeps them in sync on its own
# and rejects writes through the content API.
# -------------------------

# URL-encode a file path, encoding each segment but preserving the slashes.
urlencode_path() {
	jq -rn --arg p "$1" '$p | split("/") | map(@uri) | join("/")'
}

# Compute the "_copy" variant of a path, inserting _copy before the extension.
#   README.md      -> README_copy.md
#   .gitignore     -> .gitignore_copy   (leading-dot files have no extension)
copy_name() {
	local path="$1" dir="" base ext
	base="$path"
	if [[ "$path" == */* ]]; then
		dir="${path%/*}/"
		base="${path##*/}"
	fi
	if [[ "$base" == *.* && "$base" != .* ]]; then
		ext="${base##*.}"
		base="${base%.*}_copy.${ext}"
	else
		base="${base}_copy"
	fi
	echo "${dir}${base}"
}

# Fetch all branches (name + commit sha) for a GitHub repo as a JSON array.
github_branches() {
	local owner="$1" repo="$2"
	local page=1 all="[]" resp count
	while true; do
		resp=$(safe_curl "${curl_opts[@]}" "https://api.github.com/repos/$owner/$repo/branches?per_page=100&page=$page") || return 1
		if echo "$resp" | jq -e 'type == "object" and has("message")' >/dev/null 2>&1; then
			return 1
		fi
		count=$(echo "$resp" | jq 'if type == "array" then length else 0 end')
		[ "$count" -eq 0 ] && break
		all=$(echo "$all" "$resp" | jq -s 'add')
		[ "$count" -lt 100 ] && break
		page=$((page + 1))
	done
	echo "$all"
}

# Emit "sha<TAB>path" lines for every blob in a GitHub commit's tree.
github_tree_blobs() {
	local owner="$1" repo="$2" commit_sha="$3" resp
	resp=$(safe_curl "${curl_opts[@]}" "https://api.github.com/repos/$owner/$repo/git/trees/$commit_sha?recursive=1") || return 1
	if echo "$resp" | jq -e 'type == "object" and has("message")' >/dev/null 2>&1; then
		return 1
	fi
	if [ "$(echo "$resp" | jq -r '.truncated')" = "true" ]; then
		echo "      ${yellow}Warning: GitHub tree for $repo is truncated; some files may be skipped.${reset}" >&2
	fi
	echo "$resp" | jq -r '.tree[] | select(.type == "blob") | "\(.sha)\t\(.path)"'
}

# Fetch the head commit SHA of a Forgejo branch (empty if the branch is missing).
forgejo_branch_sha() {
	local owner="$1" repo="$2" branch="$3" resp
	resp=$(safe_curl -H "Authorization: token $FORGEJO_TOKEN" "$FORGEJO_URL/api/v1/repos/$owner/$repo/branches/$(urlencode_path "$branch")") || return 1
	echo "$resp" | jq -r '.commit.id // empty'
}

# Emit "sha<TAB>path" lines for every blob in a Forgejo commit's tree (paginated).
forgejo_tree_blobs() {
	local owner="$1" repo="$2" commit_sha="$3"
	local page=1 resp total page_count collected=0
	while true; do
		resp=$(safe_curl -H "Authorization: token $FORGEJO_TOKEN" "$FORGEJO_URL/api/v1/repos/$owner/$repo/git/trees/$commit_sha?recursive=true&per_page=1000&page=$page") || return 1
		total=$(echo "$resp" | jq -r '.total_count // 0')
		page_count=$(echo "$resp" | jq -r '(.tree // []) | length')
		[ "$page_count" -eq 0 ] && break
		echo "$resp" | jq -r '.tree[] | select(.type == "blob") | "\(.sha)\t\(.path)"'
		collected=$((collected + page_count))
		[ "$collected" -ge "$total" ] && break
		page=$((page + 1))
	done
}

# Fetch a GitHub blob's content as single-line base64 (suitable for Forgejo's API).
github_blob_content() {
	local owner="$1" repo="$2" sha="$3" resp
	resp=$(safe_curl "${curl_opts[@]}" "https://api.github.com/repos/$owner/$repo/git/blobs/$sha") || return 1
	echo "$resp" | jq -r '.content' | tr -d '\n'
}

# Create a file on a Forgejo branch from GitHub blob content.
# Args: gh_owner fj_owner repo branch filepath blob_sha kind [src_path]
forgejo_create_file() {
	local gh_owner="$1" fj_owner="$2" repo="$3" branch="$4" filepath="$5" blob_sha="$6" kind="$7" src_path="$8"
	if [ "$kind" = "copy" ]; then
		echo -ne "      ${cyan}Adding copy ${white}$filepath${cyan} (differs from ${src_path})...${reset}"
	else
		echo -ne "      ${green}Adding new file ${white}$filepath${green}...${reset}"
	fi
	if $DRY_RUN; then
		echo -e " ${cyan}[DRY RUN]${reset}"
		return 0
	fi

	local content
	content=$(github_blob_content "$gh_owner" "$repo" "$blob_sha") || {
		echo -e " ${red}Failed to fetch GitHub content.${reset}"
		return 1
	}
	local payload
	payload=$(jq -n --arg c "$content" --arg b "$branch" --arg m "Sync from GitHub: add $filepath" \
		'{content: $c, branch: $b, message: $m}')
	local resp
	resp=$(safe_curl -X POST -H "Content-Type: application/json" -H "Authorization: token $FORGEJO_TOKEN" \
		-d "$payload" "$FORGEJO_URL/api/v1/repos/$fj_owner/$repo/contents/$(urlencode_path "$filepath")") || {
		echo -e " ${red}Request failed.${reset}"
		return 1
	}
	local err
	err=$(echo "$resp" | jq -r '.message // empty')
	if [[ "$err" == *"already exists"* ]]; then
		# A previous run already created this file; fall back to an update.
		local existing
		existing=$(forgejo_file_sha "$fj_owner" "$repo" "$branch" "$filepath")
		if [ -n "$existing" ]; then
			echo -ne " ${yellow}exists, updating...${reset}"
			forgejo_update_file "$gh_owner" "$fj_owner" "$repo" "$branch" "$filepath" "$blob_sha" "$existing" "inline"
			return $?
		fi
		echo -e " ${red}Error: $err${reset}"
		return 1
	elif [ -n "$err" ]; then
		echo -e " ${red}Error: $err${reset}"
		return 1
	fi
	echo -e " ${green}Done!${reset}"
}

# Look up the current blob SHA of a file on a Forgejo branch (empty if absent).
forgejo_file_sha() {
	local owner="$1" repo="$2" branch="$3" filepath="$4" resp
	resp=$(safe_curl -H "Authorization: token $FORGEJO_TOKEN" \
		"$FORGEJO_URL/api/v1/repos/$owner/$repo/contents/$(urlencode_path "$filepath")?ref=$(urlencode_path "$branch")") || return 1
	echo "$resp" | jq -r '.sha // empty'
}

# Overwrite an existing Forgejo file with GitHub blob content.
# Args: gh_owner fj_owner repo branch filepath blob_sha existing_sha [mode]
# When mode is "inline" the leading status message is suppressed (caller printed it).
forgejo_update_file() {
	local gh_owner="$1" fj_owner="$2" repo="$3" branch="$4" filepath="$5" blob_sha="$6" existing_sha="$7" mode="$8"
	if [ "$mode" != "inline" ]; then
		echo -ne "      ${yellow}Overwriting ${white}$filepath${yellow}...${reset}"
	fi
	if $DRY_RUN; then
		echo -e " ${cyan}[DRY RUN]${reset}"
		return 0
	fi

	local content
	content=$(github_blob_content "$gh_owner" "$repo" "$blob_sha") || {
		echo -e " ${red}Failed to fetch GitHub content.${reset}"
		return 1
	}
	local payload
	payload=$(jq -n --arg c "$content" --arg b "$branch" --arg s "$existing_sha" --arg m "Sync from GitHub: update $filepath" \
		'{content: $c, branch: $b, sha: $s, message: $m}')
	local resp
	resp=$(safe_curl -X PUT -H "Content-Type: application/json" -H "Authorization: token $FORGEJO_TOKEN" \
		-d "$payload" "$FORGEJO_URL/api/v1/repos/$fj_owner/$repo/contents/$(urlencode_path "$filepath")") || {
		echo -e " ${red}Request failed.${reset}"
		return 1
	}
	local err
	err=$(echo "$resp" | jq -r '.message // empty')
	if [ -n "$err" ]; then
		echo -e " ${red}Error: $err${reset}"
		return 1
	fi
	echo -e " ${green}Done!${reset}"
}

# Compare a repo's GitHub and Forgejo trees across all branches and import
# new/changed GitHub files into Forgejo according to OVERWRITES.
sync_repo_files() {
	local gh_owner="$1" fj_owner="$2" repo="$3"
	local branches
	branches=$(github_branches "$gh_owner" "$repo") || {
		echo -e "    ${red}Could not list GitHub branches for $repo; skipping file sync.${reset}"
		return 1
	}

	echo "$branches" | jq -c '.[]' | while read -r br; do
		local branch gh_commit fj_commit
		branch=$(echo "$br" | jq -r '.name')
		gh_commit=$(echo "$br" | jq -r '.commit.sha')

		fj_commit=$(forgejo_branch_sha "$fj_owner" "$repo" "$branch")
		if [ -z "$fj_commit" ]; then
			echo -e "    ${yellow}Branch ${white}$branch${yellow} not found on Forgejo; skipping.${reset}"
			continue
		fi

		# Map of Forgejo path -> blob sha for this branch.
		declare -A fj_map=()
		while IFS=$'\t' read -r fsha fpath; do
			[ -z "$fpath" ] && continue
			fj_map["$fpath"]="$fsha"
		done < <(forgejo_tree_blobs "$fj_owner" "$repo" "$fj_commit")

		local changes=0
		while IFS=$'\t' read -r gsha gpath; do
			[ -z "$gpath" ] && continue
			local existing="${fj_map[$gpath]:-}"
			if [ "$existing" = "$gsha" ]; then
				# Identical blob SHA: file already matches GitHub, nothing to do.
				continue
			elif [ -z "$existing" ]; then
				# Present on GitHub, absent on Forgejo: import it.
				forgejo_create_file "$gh_owner" "$fj_owner" "$repo" "$branch" "$gpath" "$gsha" "new"
				changes=$((changes + 1))
			elif [ "$OVERWRITES" = true ]; then
				# Differs and overwriting is allowed: replace the Forgejo file.
				forgejo_update_file "$gh_owner" "$fj_owner" "$repo" "$branch" "$gpath" "$gsha" "$existing"
				changes=$((changes + 1))
			else
				# Differs and overwriting is disabled: keep both as <name>_copy.<ext>.
				local copypath copy_existing
				copypath="$(copy_name "$gpath")"
				copy_existing="${fj_map[$copypath]:-}"
				if [ "$copy_existing" = "$gsha" ]; then
					# A copy from a previous run already matches GitHub; skip.
					continue
				elif [ -n "$copy_existing" ]; then
					forgejo_update_file "$gh_owner" "$fj_owner" "$repo" "$branch" "$copypath" "$gsha" "$copy_existing"
				else
					forgejo_create_file "$gh_owner" "$fj_owner" "$repo" "$branch" "$copypath" "$gsha" "copy" "$gpath"
				fi
				changes=$((changes + 1))
			fi
		done < <(github_tree_blobs "$gh_owner" "$repo" "$gh_commit")

		if [ "$changes" -eq 0 ]; then
			echo -e "    ${green}Branch ${white}$branch${green} is already up to date.${reset}"
		fi
	done
}

# -------------------------
# 3. Migrate each GitHub repository to Forgejo.
# -------------------------
repo_count=$(echo "$all_repos" | jq 'length')
if [ "$repo_count" -eq 0 ]; then
	echo "No repositories found for user $GITHUB_USER."
	exit 0
fi

# The file-level sync only runs for the "clone" strategy. Mirrors are kept in
# sync by Forgejo automatically and reject writes through the content API.
if [ "$STRATEGY" = "mirror" ]; then
	echo -e "${yellow}Note: per-file sync is skipped for the 'mirror' strategy (Forgejo keeps mirrors in sync and they are read-only via the API).${reset}"
fi

# Process each GitHub repo
echo "$all_repos" | jq -c '.[]' | while read -r repo; do
	repo_name=$(echo "$repo" | jq -r '.name')
	html_url=$(echo "$repo" | jq -r '.html_url')
	private_flag=$(echo "$repo" | jq -r '.private')
	archived_flag=$(echo "$repo" | jq -r '.archived')
	full_name=$(echo "$repo" | jq -r '.full_name')
	fork_flag=$(echo "$repo" | jq -r '.fork')

	# Skip forked repos if MIGRATE_FORKS is false
	if [ "$fork_flag" = "true" ] && [ "$MIGRATE_FORKS" = false ]; then
		echo -e "${yellow}Skipping fork: ${white}$repo_name${reset}"
		continue
	fi

	# Prepare status message.
	# Capitalize the strategy for display.
	strategy_display="$(tr '[:lower:]' '[:upper:]' <<<"${STRATEGY:0:1}")${STRATEGY:1}"
	if [ "$private_flag" = "true" ]; then
		access_type="${red}private${reset}"
	else
		access_type="${green}public${reset}"
	fi
	echo -ne "${blue}${strategy_display}ing ${access_type} repository ${purple}$html_url${blue} to ${white}$FORGEJO_URL/$FORGEJO_USER/$repo_name${blue}...${reset}"

	# Determine which clone address to use.
	if [ "$private_flag" = "true" ]; then
		if [ -z "$GITHUB_TOKEN" ]; then
			echo -e " ${red}Error: Private repo but no GitHub token provided!${reset}"
			continue
		fi
	fi
	# Always use the standard URL; authentication is passed via auth_token in the payload.
	github_repo_url="$html_url"

	# Set mirror flag for the migration API:
	if [ "$STRATEGY" = "clone" ]; then
		mirror=false
	else
		mirror=true
	fi

	# Build the JSON payload.
	payload=$(jq -n \
		--arg addr "$github_repo_url" \
		--argjson mirror "$mirror" \
		--argjson private "$private_flag" \
		--arg owner "$FORGEJO_USER" \
		--arg repo "$repo_name" \
		--arg auth_token "$GITHUB_TOKEN" \
		'{clone_addr: $addr, mirror: $mirror, private: $private, repo_owner: $owner, repo_name: $repo, auth_token: (if $auth_token != "" then $auth_token else null end)}')

	if ! $DRY_RUN; then
		# Send the POST request to the Forgejo migration endpoint.
		response=$(safe_curl -H "Content-Type: application/json" -H "Authorization: token $FORGEJO_TOKEN" -d "$payload" "$FORGEJO_URL/api/v1/repos/migrate") || {
			echo -e " ${red}Migration request failed.${reset}"
			continue
		}
		error_message=$(echo "$response" | jq -r '.message // empty')

		success=false
		if [[ "$error_message" == *"already exists"* ]]; then
			echo -e " ${yellow}Already exists!${reset}"
			success=true
		elif [ -n "$error_message" ]; then
			echo -e " ${red}Unknown error: $error_message${reset}"
		else
			echo -e " ${green}Success!${reset}"
			success=true
		fi
	else
		echo -e "\n${cyan}[DRY RUN] Would migrate: $repo_name${reset}"
		success=true
	fi

	# If migration succeeded (or already existed) and the repo is archived on GitHub,
	# and the user wants to transfer archive status, patch the Forgejo repo.
	if [ "$success" = true ] && [ "$archived_flag" = "true" ] && [ "$MIGRATE_ARCHIVE_STATUS" = true ]; then
		if [ "$mirror" = true ]; then
			echo -e "  ${yellow}Skipping archive status transfer (not supported for mirrors).${reset}"
		else
			if ! $DRY_RUN; then
				echo -ne "  ${yellow}Archiving repository on Forgejo...${reset}"
				patch_payload='{"archived": true}'
				if ! patch_response=$(safe_curl -X PATCH -H "Content-Type: application/json" -H "Authorization: token $FORGEJO_TOKEN" -d "$patch_payload" "$FORGEJO_URL/api/v1/repos/$FORGEJO_USER/$repo_name"); then
					echo -e " ${red}Archive request failed.${reset}"
				else
					patch_error=$(echo "$patch_response" | jq -r '.message // empty')
					if [ -n "$patch_error" ]; then
						echo -e " ${red}Error: $patch_error${reset}"
					else
						echo -e " ${green}Done!${reset}"
					fi
				fi
			else
				echo -e " ${cyan}[DRY RUN] Would archive: $repo_name${reset}"
			fi
		fi
	fi

	# File-level sync: import new/changed GitHub files into the Forgejo clone.
	# Only meaningful for the "clone" strategy (mirrors are read-only on Forgejo).
	if [ "$success" = true ] && [ "$STRATEGY" = "clone" ]; then
		if [ "$OVERWRITES" = true ]; then
			echo -e "  ${blue}Syncing files (OVERWRITES=YES: differing files will be overwritten)...${reset}"
		else
			echo -e "  ${blue}Syncing files (OVERWRITES=NO: differing files will be added as *_copy)...${reset}"
		fi
		sync_repo_files "$GITHUB_USER" "$FORGEJO_USER" "$repo_name"
	fi
done
