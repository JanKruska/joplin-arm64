#!/usr/bin/bash

set -eu

basedir=$(readlink -f $(dirname "$0"))

# Where source files are cloned from github
repo="laurent22/joplin"
srcdir="/tmp/github_joplin"

# npm cache directory for building stage
npmcache="${srcdir}/npm-cache"

npminstall="npm install --cache ${npmcache}"
npmclient="npm"

# where files are packaged
distdir=${basedir}/dist

#Directory for .desktop files
desktop_dir="$HOME/.local/share/applications"



# while [ -n "${1-}" ]
# do
#     case "$1" in 
#     --use-pnpm)  npmclient="pnpm";;
#     --use-yarn) npmclient="yarn";;
#     esac
#     shift
# done

download() {
	# fetch latest version tag
	tag=`curl -s https://api.github.com/repos/${repo}/releases/latest |
		grep '\"tag_name\"' |
		sed -E 's/.*:\s*"([^"]+)".*/\1/'`

	# clone that branch only
	echo "Cloning ${repo} ${tag} into ${srcdir}..."
	git clone -q -b ${tag} --single-branch --depth 1 https://github.com/${repo} ${srcdir}
}

build() {
	# This script is inspired by the PKGBUILD script in 
	# https://aur.archlinux.org/packages/joplin/
	cd ${srcdir}

	# Remove husky (git hooks) from dependencies
	sed -i '/"husky": ".*"/d' package.json
	
	echo "Tweaking lerna.json"
    tmp_json="$(mktemp --tmpdir="$srcdir")"
    lerna_json="${srcdir}/lerna.json"
    jq ".packages = [
            \"packages/app-cli\", \"packages/app-desktop\",
            \"packages/fork-htmlparser2\", \"packages/fork-sax\",
            \"packages/lib\", \"packages/renderer\", \"packages/tools\",
            \"packages/turndown\", \"packages/turndown-plugin-gfm\"
            ] |
        . += {\"npmClient\": \"${npmclient}\", \"npmClientArgs\": [\"--cache $npmcache\"]}" \
        "$lerna_json" > "$tmp_json"
    cat "$tmp_json" > "$lerna_json"
    rm "$tmp_json"

	# Force Lang
	# INFO: https://github.com/alfredopalhares/joplin-pkgbuild/issues/25
	export LANG=en_US.utf8

	# Modify build to remove usages of the keytar module from code, which is
	# not available for arm64 architecture
	sed -i '/"keytar": ".*"/d' packages/app-cli/package.json
	sed -i '/"keytar": ".*"/d' packages/app-desktop/package.json

	# Patch ReactNative client code to remove usage of keytar. This code is
	# copied into the Cli and Electron apps as part of the joplin build
	#git apply ${basedir}/keytar.patch

	# This shares an npmcache directory, and will take a *while* if compiling
	# from scratch. It also seems to be building dependencies such as sqlite3
	# several times. This can all likely be sped up significantly.

	# npm complains for missing execa package - force to install it
	${npminstall} execa
	${npminstall}

	# CliClient
	cd packages/app-cli
	npm run build
	echo "Cli Client built"
	cd ${srcdir}

	# Electron App
	cd packages/app-desktop
	npm run build
	echo "Electron Client built"
	npm run dist

	cd ${basedir}
}

package() {
	cd ${srcdir}
	version=`git tag | tail -c +2`
	cd ..

	dst=${distdir}/joplin-${version}
	echo "Packaging into ${dst}"

	# cli client

	librelative=lib/node_modules/joplin
	libdir=${dst}/joplin-cli/${librelative}
	mkdir -p ${libdir}
	cp -R ${srcdir}/packages/app-cli/build/* ${libdir}
	cp -R ${srcdir}/packages/app-cli/node_modules ${libdir}

	bindir=${dst}/joplin-cli/bin
	mkdir -p ${bindir}
	ln -s ../${librelative}/main.js ${bindir}/joplin

	# electron client
	mkdir -p ${dst}/joplin
	cp -R ${srcdir}/packages/app-desktop/dist/*.AppImage ${dst}/joplin
	cp -R ${srcdir}/packages/app-desktop/build/icons/128x128.png ${dst}/joplin
    
	cd ${basedir}
}

cleanup() {
	echo "Cleaning up ${srcdir}"
	rm -rf ${srcdir}
}

# Clean old sources
cleanup

# Download sources
download

# Expand sources and compile code
build

# Package up dist files
package

# cleanup sources
cleanup

echo "Process terminated successfully. Results in ${distdir}"
