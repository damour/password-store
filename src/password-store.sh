#!/bin/bash

# Copyright (C) 2012 - 2014 Jason A. Donenfeld <Jason@zx2c4.com>. All Rights Reserved.
# This file is licensed under the GPLv2+. Please see COPYING for more information.

umask "${PASSWORD_STORE_UMASK:-077}"
set -o pipefail

GPG_OPTS="--quiet --yes --compress-algo=none"
GPG="gpg"
which gpg2 &>/dev/null && GPG="gpg2"
[[ -n $GPG_AGENT_INFO || $GPG == "gpg2" ]] && GPG_OPTS="$GPG_OPTS --batch --use-agent"

PREFIX="${PASSWORD_STORE_DIR:-$HOME/.password-store}"
X_SELECTION="${PASSWORD_STORE_X_SELECTION:-clipboard}"
CLIP_TIME="${PASSWORD_STORE_CLIP_TIME:-45}"

export GIT_DIR="${PASSWORD_STORE_GIT:-$PREFIX}/.git"
export GIT_WORK_TREE="${PASSWORD_STORE_GIT:-$PREFIX}"

#
# BEGIN helper functions
#

git_add_file() {
	[[ -d $GIT_DIR ]] || return
	git add "$1" || return
	[[ -n $(git status --porcelain "$1") ]] || return
	[[ $(git config --bool --get pass.signcommits) == "true" ]] && sign="-S" || sign=""
	git commit $sign -m "$2"
}
yesno() {
	local response
	read -r -p "$1 [y/N] " response
	[[ $response == [yY] ]] || exit 1
}
set_gpg_recipients() {
	GPG_RECIPIENT_ARGS=( )

	if [[ -n $PASSWORD_STORE_KEY ]]; then
		for gpg_id in $PASSWORD_STORE_KEY; do
			GPG_RECIPIENT_ARGS+=( "-r" "$gpg_id" )
		done
		return
	fi

	local current="$PREFIX/$1"
	while [[ $current != "$PREFIX" && ! -f $current/.gpg-id ]]; do
		current="${current%/*}"
	done
	current="$current/.gpg-id"

	if [[ ! -f $current ]]; then
		cat <<-_EOF
		ERROR: You must run:
		    $PROGRAM init your-gpg-id
		before you may use the password store.

		_EOF
		cmd_usage
		exit 1
	fi

	while read -r gpg_id; do
		GPG_RECIPIENT_ARGS+=( "-r" "$gpg_id" )
	done < "$current"
}
agent_check() {
	[[ -n $GPG_AGENT_INFO ]] || yesno "$(cat <<-_EOF
	You are not running gpg-agent. This means that you will
	need to enter your password for each and every gpg file
	that pass processes. This could be quite tedious.

	Are you sure you would like to continue without gpg-agent?
	_EOF
	)"
}

#
# END helper functions
#

#
# BEGIN platform definable
#

clip() {
	# This base64 business is a disgusting hack to deal with newline inconsistancies
	# in shell. There must be a better way to deal with this, but because I'm a dolt,
	# we're going with this for now.

	local sleep_argv0="password store sleep on display $DISPLAY"
	pkill -f "^$sleep_argv0" 2>/dev/null && sleep 0.5
	local before="$(xclip -o -selection "$X_SELECTION" | base64)"
	echo -n "$1" | xclip -selection "$X_SELECTION"
	(
		( exec -a "$sleep_argv0" sleep "$CLIP_TIME" )
		local now="$(xclip -o -selection "$X_SELECTION" | base64)"
		[[ $now != $(echo -n "$1" | base64) ]] && before="$now"

		# It might be nice to programatically check to see if klipper exists,
		# as well as checking for other common clipboard managers. But for now,
		# this works fine -- if qdbus isn't there or if klipper isn't running,
		# this essentially becomes a no-op.
		#
		# Clipboard managers frequently write their history out in plaintext,
		# so we axe it here:
		qdbus org.kde.klipper /klipper org.kde.klipper.klipper.clearClipboardHistory &>/dev/null

		echo "$before" | base64 -d | xclip -selection "$X_SELECTION"
	) 2>/dev/null & disown
	echo "Copied $2 to clipboard. Will clear in $CLIP_TIME seconds."
}
tmpdir() {
	if [[ -d /dev/shm && -w /dev/shm && -x /dev/shm ]]; then
		SECURE_TMPDIR="$(TMPDIR=/dev/shm mktemp -d -t "$template")"
	else
		yesno "$(cat <<-_EOF
		Your system does not have /dev/shm, which means that it may
		be difficult to entirely erase the temporary non-encrypted
		password file after editing.

		Are you sure you would like to continue?
		_EOF
		)"
		SECURE_TMPDIR="$(mktemp -d -t "$template")"
	fi

}
GETOPT="getopt"
SHRED="shred -f -z"

# source /path/to/platform-defined-functions

#
# END platform definable
#


#
# BEGIN subcommand functions
#

cmd_version() {
	cat <<-_EOF
	============================================
	= pass: the standard unix password manager =
	=                                          =
	=                   v1.6                   =
	=                                          =
	=             Jason A. Donenfeld           =
	=               Jason@zx2c4.com            =
	=                                          =
	= http://zx2c4.com/projects/password-store =
	============================================
	_EOF
}

cmd_usage() {
	cmd_version
	echo
	cat <<-_EOF
	Usage:
	    $PROGRAM init [--reencrypt,-e] [--path=subfolder,-p subfolder] gpg-id...
	        Initialize new password storage and use gpg-id for encryption.
	        Optionally reencrypt existing passwords using new gpg-id.
	    $PROGRAM [ls] [subfolder]
	        List passwords.
	    $PROGRAM find pass-names...
	    	List passwords that match pass-names.
	    $PROGRAM [show] [--clip,-c] pass-name
	        Show existing password and optionally put it on the clipboard.
	        If put on the clipboard, it will be cleared in $CLIP_TIME seconds.
	    $PROGRAM grep search-string
	        Search for password files containing search-string when decrypted.
	    $PROGRAM insert [--echo,-e | --multiline,-m] [--force,-f] pass-name
	        Insert new password. Optionally, echo the password back to the console
	        during entry. Or, optionally, the entry may be multiline. Prompt before
	        overwriting existing password unless forced.
	    $PROGRAM edit pass-name
	        Insert a new password or edit an existing password using ${EDITOR:-vi}.
	    $PROGRAM generate [--no-symbols,-n] [--clip,-c] [--force,-f] pass-name pass-length
	        Generate a new password of pass-length with optionally no symbols.
	        Optionally put it on the clipboard and clear board after 45 seconds.
	        Prompt before overwriting existing password unless forced.
	    $PROGRAM rm [--recursive,-r] [--force,-f] pass-name
	        Remove existing password or directory, optionally forcefully.
	    $PROGRAM git git-command-args...
	        If the password store is a git repository, execute a git command
	        specified by git-command-args.
	    $PROGRAM help
	        Show this text.
	    $PROGRAM version
	        Show version information.

	More information may be found in the pass(1) man page.
	_EOF
}

cmd_init() {
	local reencrypt=0
	local id_path=""

	local opts
	opts="$($GETOPT -o ep: -l reencrypt,path: -n "$PROGRAM" -- "$@")"
	local err=$?
	eval set -- "$opts"
	while true; do case $1 in
		-e|--reencrypt) reencrypt=1; shift ;;
		-p|--path) id_path="$2"; shift 2 ;;
		--) shift; break ;;
	esac done

	if [[ $err -ne 0 || $# -lt 1 ]]; then
		echo "Usage: $PROGRAM $COMMAND [--reencrypt,-e] [--path=subfolder,-p subfolder] gpg-id..."
		exit 1
	fi
	if [[ -n $id_path && ! -d $PREFIX/$id_path ]]; then
		if [[ -e $PREFIX/$id_path ]]; then
			echo "Error: $PREFIX/$id_path exists but is not a directory."
			exit 1;
		fi
	fi

	mkdir -v -p "$PREFIX/$id_path"
	local gpg_id="$PREFIX/$id_path/.gpg-id"
	printf "%s\n" "$@" > "$gpg_id"
	local id_print="$(printf "%s, " "$@")"
	echo "Password store initialized for ${id_print%, }"
	git_add_file "$gpg_id" "Set GPG id to ${id_print%, }."

	if [[ $reencrypt -eq 1 ]]; then
		agent_check
		local passfile
		find "$PREFIX/$id_path" -iname '*.gpg' | while read -r passfile; do
			fake_uniqueness_safety="$RANDOM"
			passfile_dir="${passfile%/*}"
			passfile_dir="${passfile_dir#$PREFIX}"
			passfile_dir="${passfile_dir#/}"
			set_gpg_recipients "$passfile_dir"
			$GPG -d $GPG_OPTS "$passfile" | $GPG -e "${GPG_RECIPIENT_ARGS[@]}" -o "$passfile.new.$fake_uniqueness_safety" $GPG_OPTS &&
			mv -v "$passfile.new.$fake_uniqueness_safety" "$passfile"
		done
		git_add_file "$PREFIX/$id_path" "Reencrypted password store using new GPG id ${id_print}."
	fi
}

cmd_show() {
	local clip=0

	local opts
	opts="$($GETOPT -o c -l clip -n "$PROGRAM" -- "$@")"
	local err=$?
	eval set -- "$opts"
	while true; do case $1 in
		-c|--clip) clip=1; shift ;;
		--) shift; break ;;
	esac done

	if [[ $err -ne 0 ]]; then
		echo "Usage: $PROGRAM $COMMAND [--clip,-c] [pass-name]"
		exit 1
	fi

	local path="$1"
	local passfile="$PREFIX/$path.gpg"
	if [[ -f $passfile ]]; then
		if [[ $clip -eq 0 ]]; then
			exec $GPG -d $GPG_OPTS "$passfile"
		else
			local pass="$($GPG -d $GPG_OPTS "$passfile" | head -n 1)"
			[[ -n $pass ]] || exit 1
			clip "$pass" "$path"
		fi
	elif [[ -d $PREFIX/$path ]]; then
		if [[ -z $path ]]; then
			echo "Password Store"
		else
			echo "${path%\/}"
		fi
		tree -l --noreport "$PREFIX/$path" | tail -n +2 | sed 's/\.gpg$//'
	else
		echo "$path is not in the password store."
		exit 1
	fi
}

cmd_find() {
	if [[ -z "$@" ]]; then
		echo "Usage: $PROGRAM $COMMAND pass-names..."
		exit 1
	fi
	if ! tree --version | grep -q "Jason A. Donenfeld"; then
		echo "ERROR: $PROGRAM: incompatible tree command"
		echo
		echo "Your version of the tree command is missing the relevent patch to add the"
		echo "--matchdirs and --caseinsensitive switches. Please ask your distribution"
		echo "to patch your version of"
		echo "tree with:"
		echo "   http://git.zx2c4.com/password-store/plain/contrib/tree-1.6.0-matchdirs.patch"
		echo "Sorry for the inconvenience."
		exit 1
	fi
	local terms="$@"
	echo "Search Terms: $terms"
	tree -l --noreport -P "*${terms// /*|*}*" --prune --matchdirs --caseinsensitive "$PREFIX" | tail -n +2 | sed 's/\.gpg$//'
}

cmd_grep() {
	if [[ $# -ne 1 ]]; then
		echo "Usage: $PROGRAM $COMMAND search-string"
		exit 1
	fi
	agent_check
	local passfile
	local passfile_dir
	local grepresults
	local search="$1"
	find "$PREFIX" -iname '*.gpg' | while read -r passfile; do
		grepresults="$($GPG -d $GPG_OPTS "$passfile" | grep --color=always "$search")"
		[ $? -ne 0 ] && continue
		passfile="${passfile%.gpg}"
		passfile="${passfile#$PREFIX/}"
		passfile_dir="${passfile%/*}"
		passfile="${passfile##*/}"
		printf "\e[94m$passfile_dir/\e[1m$passfile\e[0m:\n"
		echo "$grepresults"
	done
}

cmd_insert() {
	local multiline=0
	local noecho=1
	local force=0

	local opts
	opts="$($GETOPT -o mef -l multiline,echo,force -n "$PROGRAM" -- "$@")"
	local err=$?
	eval set -- "$opts"
	while true; do case $1 in
		-m|--multiline) multiline=1; shift ;;
		-e|--echo) noecho=0; shift ;;
		-f|--force) force=1; shift ;;
		--) shift; break ;;
	esac done

	if [[ $err -ne 0 || ( $multiline -eq 1 && $noecho -eq 0 ) || $# -ne 1 ]]; then
		echo "Usage: $PROGRAM $COMMAND [--echo,-e | --multiline,-m] [--force,-f] pass-name"
		exit 1
	fi
	local path="$1"
	local passfile="$PREFIX/$path.gpg"

	[[ $force -eq 0 && -e $passfile ]] && yesno "An entry already exists for $path. Overwrite it?"

	mkdir -p -v "$PREFIX/$(dirname "$path")"
	set_gpg_recipients "$(dirname "$path")"

	if [[ $multiline -eq 1 ]]; then
		echo "Enter contents of $path and press Ctrl+D when finished:"
		echo
		$GPG -e "${GPG_RECIPIENT_ARGS[@]}" -o "$passfile" $GPG_OPTS
	elif [[ $noecho -eq 1 ]]; then
		local password
		local password_again
		while true; do
			read -r -p "Enter password for $path: " -s password
			echo
			read -r -p "Retype password for $path: " -s password_again
			echo
			if [[ $password == "$password_again" ]]; then
				$GPG -e "${GPG_RECIPIENT_ARGS[@]}" -o "$passfile" $GPG_OPTS <<<"$password"
				break
			else
				echo "Error: the entered passwords do not match."
			fi
		done
	else
		local password
		read -r -p "Enter password for $path: " -e password
		$GPG -e "${GPG_RECIPIENT_ARGS[@]}" -o "$passfile" $GPG_OPTS <<<"$password"
	fi
	git_add_file "$passfile" "Added given password for $path to store."
}

cmd_edit() {
	if [[ $# -ne 1 ]]; then
		echo "Usage: $PROGRAM $COMMAND pass-name"
		exit 1
	fi

	local path="$1"
	mkdir -p -v "$PREFIX/$(dirname "$path")"
	set_gpg_recipients "$(dirname "$path")"
	local passfile="$PREFIX/$path.gpg"
	local template="$PROGRAM.XXXXXXXXXXXXX"

	trap '$SHRED "$tmp_file"; rm -rf "$SECURE_TMPDIR" "$tmp_file"' INT TERM EXIT

	tmpdir #Defines $SECURE_TMPDIR
	local tmp_file="$(TMPDIR="$SECURE_TMPDIR" mktemp -t "$template")"

	local action="Added"
	if [[ -f $passfile ]]; then
		$GPG -d -o "$tmp_file" $GPG_OPTS "$passfile" || exit 1
		action="Edited"
	fi
	${EDITOR:-vi} "$tmp_file"
	while ! $GPG -e "${GPG_RECIPIENT_ARGS[@]}" -o "$passfile" $GPG_OPTS "$tmp_file"; do
		echo "GPG encryption failed. Retrying."
		sleep 1
	done
	git_add_file "$passfile" "$action password for $path using ${EDITOR:-vi}."
}

cmd_generate() {
	local clip=0
	local force=0
	local symbols="-y"

	local opts
	opts="$($GETOPT -o ncf -l no-symbols,clip,force -n "$PROGRAM" -- "$@")"
	local err=$?
	eval set -- "$opts"
	while true; do case $1 in
		-n|--no-symbols) symbols=""; shift ;;
		-c|--clip) clip=1; shift ;;
		-f|--force) force=1; shift ;;
		--) shift; break ;;
	esac done

	if [[ $err -ne 0 || $# -ne 2 ]]; then
		echo "Usage: $PROGRAM $COMMAND [--no-symbols,-n] [--clip,-c] [--force,-f] pass-name pass-length"
		exit 1
	fi
	local path="$1"
	local length="$2"
	if [[ ! $length =~ ^[0-9]+$ ]]; then
		echo "pass-length \"$length\" must be a number."
		exit 1
	fi
	mkdir -p -v "$PREFIX/$(dirname "$path")"
	set_gpg_recipients "$(dirname "$path")"
	local passfile="$PREFIX/$path.gpg"

	[[ $force -eq 0 && -e $passfile ]] && yesno "An entry already exists for $path. Overwrite it?"

	local pass="$(pwgen -s $symbols $length 1)"
	[[ -n $pass ]] || exit 1
	$GPG -e "${GPG_RECIPIENT_ARGS[@]}" -o "$passfile" $GPG_OPTS <<<"$pass"
	git_add_file "$passfile" "Added generated password for $path to store."

	if [[ $clip -eq 0 ]]; then
		echo "The generated password to $path is:"
		echo "$pass"
	else
		clip "$pass" "$path"
	fi
}

cmd_delete() {
	local recursive=""
	local force=0

	local opts
	opts="$($GETOPT -o rf -l recursive,force -n "$PROGRAM" -- "$@")"
	local err=$?
	eval set -- "$opts"
	while true; do case $1 in
		-r|--recursive) recursive="-r"; shift ;;
		-f|--force) force=1; shift ;;
		--) shift; break ;;
	esac done
	if [[ $# -ne 1 ]]; then
		echo "Usage: $PROGRAM $COMMAND [--recursive,-r] [--force,-f] pass-name"
		exit 1
	fi
	local path="$1"

	local passfile="$PREFIX/${path%/}"
	if [[ ! -d $passfile ]]; then
		passfile="$PREFIX/$path.gpg"
		if [[ ! -f $passfile ]]; then
			echo "$path is not in the password store."
			exit 1
		fi
	fi

	[[ $force -eq 1 ]] || yesno "Are you sure you would like to delete $path?"

	rm $recursive -f -v "$passfile"
	if [[ -d $GIT_DIR && ! -e $passfile ]]; then
		git rm -qr "$passfile"
		git commit -m "Removed $path from store."
	fi
}

cmd_git() {
	if [[ $1 == "init" ]]; then
		git "$@" || exit 1
		git_add_file "$PREFIX" "Added current contents of password store."
	elif [[ -d $GIT_DIR ]]; then
		exec git "$@"
	else
		echo "Error: the password store is not a git repository."
		exit 1
	fi
}

#
# END subcommand functions
#

PROGRAM="${0##*/}"
COMMAND="$1"

case "$1" in
	init) shift;			cmd_init "$@"; ;;
	help|--help) shift;		cmd_usage "$@"; ;;
	version|--version) shift;	cmd_version "$@"; ;;
	show|ls|list) shift;		cmd_show "$@"; ;;
	find|search) shift;		cmd_find "$@"; ;;
	grep) shift;			cmd_grep "$@"; ;;
	insert) shift;			cmd_insert "$@"; ;;
	edit) shift;			cmd_edit "$@"; ;;
	generate) shift;		cmd_generate "$@"; ;;
	delete|rm|remove) shift;	cmd_delete "$@"; ;;
	git) shift;			cmd_git "$@"; ;;
	*) COMMAND="show";		cmd_show "$@"; ;;
esac
exit 0
