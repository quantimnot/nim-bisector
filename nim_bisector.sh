#!/bin/sh -e

# the Nim compiler that will build other Nim compilers
nim=${NIM:-nim}
nimrepo=${NIMREPO:-Nim}
nimcache=${NIMCACHE:-nimcache}

if [ ! -d "${nimrepo}" ]
then git clone "https://github.com/nim-lang/Nim.git" "${nimrepo}"
fi

if [ ! -d "${nimcache}" ]
then mkdir -p "${nimcache}"
fi

good=v1.4.8
bad=devel
testcase="tests/issues/tmain.nim"

reset() {
	{
		git reset --hard
		git clean -fdx
		git clean -fX
	} >/dev/null 2>&1
}

cd "${nimrepo}"
git co "${good}"
reset
git bisect start "${bad}" "${good}"

while true
do
	timestamp=$(git log -n 1 --format=%at)
	revision=$(git rev-parse HEAD)
	out="../${nimcache}/${timestamp}-${revision}"

	if [ ! -x "${out}" ]
	then
		printf '%s' "compiling ${out}"
		if [ -z "${NIM:-}" ]
		then
			if [ -f build_all.sh ]
			then
				if sed '/echo_run .\/koch/d' build_all.sh | sh >/dev/null 2>&1
				then nim=bin/nim
				else
					echo " - skipping"
					reset
					git bisect skip; continue
				fi
			else echo FIXME; break
			fi
		fi
		if "${nim}" c -f -d:release --hints:off --skipUserCfg --skipParentCfg --lib:lib -o:"${out}" compiler/nim.nim >/dev/null 2>&1
		then
			echo " - done"
		else
			echo " - skipping"
			reset
			git bisect skip; continue
		fi
	else
		echo "using cached ${out}"
	fi

	printf '%s' "${revision}: running test"
  if testament --nim:"${out}" --targets:"c" r "../${testcase}" >/dev/null 2>&1
	then
		echo " - pass"
		reset
		git bisect good
	else
		echo " - fail"
		reset
		if git bisect bad | grep -E '^[a-z0-9]{40}' #awk 'NR==1 && /^[a-z0-9]{40}/ {print $1}'
		then
			reset
			break
		fi
	fi
done
