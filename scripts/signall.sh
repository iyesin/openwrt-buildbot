#!/usr/bin/env bash

tarball="$1"
branch="$2"

tmpdir="signall.$$"
tarball="$(readlink -f "$tarball")"

finish() { rm -rf "$tmpdir"; exit $1; }

iniget() {
	local file="$1" section="$2" option="$3"

	sed -rne '
		/\['"$section"'\]/,$ {
			/^[ \t]*'"$option"'[ \t]*=[ \t]*/ {
				s/^[^=]+=[ \t]*//; h;
				:c; n;
				/^([ \t]|$)/ {
					s/^[ \t]+//; H;
					b c
				};
				x; p; q
			}
		}
	' "$file" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
}

trap "finish 255" HUP INT TERM

if [ ! -f "$tarball" ] || [ ! -f "${CONFIG_INI:-config.ini}" ]; then
	echo "Usage: [CONFIG_INI=...] $0 <tarball>" >&2
	finish 1
fi

[ ! -e "$tmpdir" ] || {
	echo "Temporary directory $tmpdir already exists!" >&2
	finish 2
}

umask 077
mkdir "$tmpdir" "$tmpdir/tar" "$tmpdir/gpg" "$tmpdir/gpg/private-keys-v1.d" || finish 2

umask 022
chmod 0755 "$tmpdir/tar"
tar -C "$tmpdir/tar/" -xzf "$tarball" || finish 3

loopback=""

case "$(gpg --version | head -n1)" in
	*\ 2.*) loopback=1 ;;
esac

if [ -z "$branch" ]; then
GPGKEY="$(iniget "${CONFIG_INI:-config.ini}" gpg key)"
GPGKEYID="$(iniget "${CONFIG_INI:-config.ini}" gpg keyid)"
GPGPASS="$(iniget "${CONFIG_INI:-config.ini}" gpg passphrase)"
GPGCOMMENT="$(iniget "${CONFIG_INI:-config.ini}" gpg comment)"

USIGNKEY="$(iniget "${CONFIG_INI:-config.ini}" usign key)"
USIGNCOMMENT="$(iniget "${CONFIG_INI:-config.ini}" usign comment)"

APKSIGNKEY="$(iniget "${CONFIG_INI:-config.ini}" apk key)"
else
GPGKEY="$(iniget "${CONFIG_INI:-config.ini}" "branch $branch" "gpg_key")"
GPGKEYID="$(iniget "${CONFIG_INI:-config.ini}" "branch $branch" "gpg_keyid")"
GPGPASS="$(iniget "${CONFIG_INI:-config.ini}" "branch $branch" "gpg_passphrase")"
GPGCOMMENT="$(iniget "${CONFIG_INI:-config.ini}" "branch $branch" "gpg_comment")"

USIGNKEY="$(iniget "${CONFIG_INI:-config.ini}" "branch $branch" "usign_key")"
USIGNCOMMENT="$(iniget "${CONFIG_INI:-config.ini}" "branch $branch" "usign_comment")"

APKSIGNKEY="$(iniget "${CONFIG_INI:-config.ini}" "branch $branch" "apk_key")"
fi

if [ -n "$APKSIGNKEY" ]; then
	umask 077
	echo "$APKSIGNKEY" > "$tmpdir/apk.pem"

	umask 022
	find "$tmpdir/tar/" -type f -name "packages.adb" -print0 | while IFS= read -r -d '' file; do
		if ! "${APK_BIN:-apk}" adbsign --allow-untrusted --sign-key "$(readlink -f "$tmpdir/apk.pem")" "$file"; then
			finish 3
		fi
	done

	find "$tmpdir/tar/" -type f -name sha256sums | while read -r file; do
		dir=$(dirname "$file")
		pushd "$dir" > /dev/null || finish 3

		grep 'packages\.adb' sha256sums | while IFS= read -r line; do
			filename="${line#*' *'}"
			# Skip updating hash of previous kmods/ if not found in sign tar (already signed)
			[ ! -f "$filename" ] && [[ "$filename" == kmods/* ]] && continue
			escaped_filename="${filename//\//\\\/}"
			escaped_filename="${escaped_filename//&/\\&}"
			checksum_output=$(sha256sum --binary -- "$filename")
			new_checksum_line="${checksum_output%% *} *${checksum_output#*' *'}"
			sed -i "s#.*[[:space:]]\*$escaped_filename\$#$new_checksum_line#" sha256sums
		done

		popd > /dev/null || finish 3
	done
fi

if echo "$GPGKEY" | grep -q "BEGIN PGP PRIVATE KEY BLOCK" && [ -z "$GPGKEYID" ]; then
	umask 077
	echo "$GPGPASS" > "$tmpdir/gpg.pass"
	echo "$GPGKEY" | gpg --batch --homedir "$tmpdir/gpg" \
		${loopback:+--pinentry-mode loopback --no-tty --passphrase-fd 0} \
		${GPGPASS:+--passphrase-file "$tmpdir/gpg.pass"} \
		--import - || finish 4

	umask 022
	find "$tmpdir/tar/" -type f -not -name "*.asc" -and -not -name "*.sig" -exec \
		gpg --no-version --batch --yes -a -b \
			--homedir "$(readlink -f "$tmpdir/gpg")" \
			${loopback:+--pinentry-mode loopback --no-tty --passphrase-fd 0} \
			${GPGPASS:+--passphrase-file "$(readlink -f "$tmpdir/gpg.pass")"} \
			${GPGCOMMENT:+--comment="$GPGCOMMENT"} \
			-o "{}.asc" "{}" \; || finish 4
fi

if [ -n "$GPGKEYID" ]; then
	find "$tmpdir/tar/" -type f -not -name "*.asc" -and -not -name "*.sig" -print0 | while IFS= read -r -d '' file; do
		if ! gpg --no-version --batch --detach-sign --armor \
			--local-user "${GPGKEYID}" \
			${GPGCOMMENT:+--comment="$GPGCOMMENT"} \
			--homedir /home/buildbot/.gnupg "${file}.asc" "$file"; then
			finish 4
		fi
	done
fi

if [ -n "$USIGNKEY" ]; then
	USIGNID="$(echo "$USIGNKEY" | base64 -d -i | dd bs=1 skip=32 count=8 2>/dev/null | od -v -t x1 | sed -rne 's/^0+ //p' | tr -d ' ')"

	if ! echo "$USIGNID" | grep -qxE "[0-9a-f]{16}"; then
		echo "Invalid usign key specified" >&2
		finish 5
	fi

	umask 077
	printf "untrusted comment: %s\n%s\n" "${USIGNCOMMENT:-key ID $USIGNID}" "$USIGNKEY" > "$tmpdir/usign.sec"

	umask 022
	find "$tmpdir/tar/" -type f -not -name "*.asc" -and -not -name "*.sig" -exec \
		signify-openbsd -S -s "$(readlink -f "$tmpdir/usign.sec")" -m "{}" \; || finish 5
fi

tar -C "$tmpdir/tar/" -czf "$tarball" . || finish 6

finish 0
