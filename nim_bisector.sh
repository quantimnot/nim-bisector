#!/bin/sh -U

# TODO: format cache timestamp as: TZ=UTC date "+%Y%m%d%H%M%S"

nim=${NIM:-nim}
bisector_home=${NIM_BISECTOR_HOME:-${PWD}}
nimrepo=${NIMREPO:-${bisector_home}/Nim}
nimcache=${NIMCACHE:-${bisector_home}/nimcache}
nimlogs=${bisector_home}/nimlogs
nimtags=${bisector_home}/nimtags
nimskip=${bisector_home}/nimskip
testlogs=${bisector_home}/testlogs

if [ ! -d "${nimrepo}" ]
then
	git clone "https://github.com/nim-lang/Nim.git" "${nimrepo}"
	git clone "https://github.com/nim-lang/csources.git" "${nimrepo}/csources"
	git clone "https://github.com/nim-lang/csources_v1.git" "${nimrepo}/csources_v1"
fi

test="${1}"
testId="$(printf '%s' "${test}" | shasum | cut -f1 -d' ')"
good="${2:-}"
bad="${3:-devel}"

if [ ! -d "${testlogs}/${testId}" ]
then mkdir -p "${testlogs}/${testId}"
fi

if [ ! -d "${nimtags}" ]
then mkdir -p "${nimtags}"
fi

if [ ! -d "${nimlogs}" ]
then mkdir -p "${nimlogs}"
fi

if [ ! -d "${nimskip}" ]
then mkdir -p "${nimskip}"
fi

if [ ! -d "${nimcache}" ]
then mkdir -p "${nimcache}"
fi

reset() {
  (
    git reset --hard
    git clean -fdx
    git clean -fX
		cd csources
    git reset --hard
    git clean -fdx
    git clean -fX
		cd csources_v1
    git reset --hard
    git clean -fdx
    git clean -fX
	 ) >/dev/null 2>&1
}

runTest() {
  printf '%s' "${revision}: running test"
  if \time -l sh -c "${test}" >"${testlogs}/${testId}/${version}.log" 2>&1
  then
    echo " - pass"
		echo "${version}" >> "${testlogs}/${testId}/pass.log"
    reset
    git bisect good
  else
    echo " - fail"
		echo "${version}" >> "${testlogs}/${testId}/fail.log"
    reset
    if git bisect bad | grep -E '^[a-z0-9]{40}' #awk 'NR==1 && /^[a-z0-9]{40}/ {print $1}'
    then
      reset
      return 1
    fi
  fi
}

build_compiler() {
	printf '%s' "compiling ${version}"
	co_csources_before_time "${timestamp}"

	timestamp=$(git log -n 1 --format=%ct)
	revision=$(git rev-parse HEAD)
	version="${timestamp}-${revision}"
	out="${nimcache}/${version}"

	if [ -f "${nimskip}/${version}" ]; then
		echo "* skipping ${version}"
		git bisect skip; continue
	fi

	if [ ! -d "${out}" ]; then
		if [ -f build_all.sh ]
		then
			if sed '/echo_run .\/koch/d' build_all.sh | sh >"${nimlogs}/${version}_csource.log" 2>&1
			then nim=bin/nim
			else
				echo " - skipping"
				touch "${nimskip}/${version}"
				reset
				return 1
			fi
		else
			if (cd csources && sh build.sh >"${nimlogs}/${version}_csource.log" 2>&1; test -x ../bin/nim)
			then nim=bin/nim
			else
				echo " - skipping"
				touch "${nimskip}/${version}"
				reset
				return 1
			fi
		fi

		if { ./bin/nim c koch && \time -l ./koch boot -d:release; } >"${nimlogs}/${version}.log" 2>&1
		then
			mkdir -p "${out}"
			cp -r bin lib config "${out}"
			export NIM="${out}/bin/nim"
			echo " - done"
		else
			echo " - skipping"
			touch "${nimskip}/${version}"
			reset
			return 1
		fi
	else
		echo "using cached ${version}"
	fi
}

prime_cache() {
	echo "* Priming cache with tag versions"
	(
		cd "${nimrepo}"
		for tag in $(git tag -l | sort -V); do
			git checkout "${tag}"
			if build_compiler; then
				ln -sf "${nimcache}/${version}" "${nimtags}/${tag}"
			else
				ln -sf "${nimskip}/${version}" "${nimtags}/${tag}"
			fi
		done
	)
}

find_good() {
	echo "* Searching for the 'good'."
	for nim in "${nimcache}"/*; do
		export NIM="${nim}/bin/nim"
		if sh -c "${test}" >/dev/null 2>&1; then
			good="${nim##*-}"
		fi
	done
	if [ -z "${good}" ]; then
		echo "* No 'good' could be found in cached compilers."
		exit 1
	fi
}

co_csources_before_time() {
	(
		cd csources
		git checkout $(git rev-list -1 --before="$1" master)
	) >/dev/null 2>&1
}

bisect_cache() {
	goodTime="$(git log -n 1 "${good}" --format=%ct)"
	badTime="$(git log -n 1 "${bad}" --format=%ct)"
	leGood=""
	leBad=""
	for t in $(ls "${nimcache}" | cut -f1 -d- | sort -r | tr '\n' ' '); do
		leGood=${t}
		# if [ ${t} -ge "${goodTime}" ]; then
		# 	echo "g < ${t}"
		if [ ${t} -le "${goodTime}" ]; then
			break
		fi
	done
	for t in $(ls "${nimcache}" | cut -f1 -d- | sort | tr '\n' ' '); do
		leBad=${t}
		if [ ${t} -ge "${badTime}" ]; then
			break
		fi
	done
	if [ ${leGood} -eq ${leBad} ]; then
		echo "* no cached ranges between known good and bad"
	else
		echo "* Testing cached ranges (commit time):"
		echo "  ${leGood}..${leBad}"
	fi
}

bisect_commits() {
	git co "${good}"
	reset
	git bisect start "${bad}" "${good}"

	while true; do
		build_compiler || { git bisect skip; continue; }
		if ! runTest; then
			break
		fi
	done
}

bisect() {
	cd "${nimrepo}"
	echo "* Known good: $(git rev-parse "${good}")"
	echo "* Known bad: $(git rev-parse "${bad}")"
	bisect_cache
	bisect_commits
}

prime_cache

if [ -z "${good}" ]; then
	echo "* No 'good' specified."
	find_good
fi

bisect
