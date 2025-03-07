package base

// This file contains aspects principally related to GitHub workflows

import (
	encjson "encoding/json"
	"strings"
	"strconv"

	"github.com/SchemaStore/schemastore/src/schemas/json"
)

bashWorkflow: json.#Workflow & {
	jobs: [string]: defaults: run: shell: "bash"
}

installGo: json.#step & {
	name: "Install Go"
	uses: "actions/setup-go@v4"
	with: {
		// We do our own caching in setupGoActionsCaches.
		cache:        false
		"go-version": string
	}
}

checkoutCode: {
	#actionsCheckout: json.#step & {
		name: "Checkout code"
		uses: "actions/checkout@v3"

		// "pull_request" builds will by default use a merge commit,
		// testing the PR's HEAD merged on top of the master branch.
		// For consistency with Gerrit, avoid that merge commit entirely.
		// This doesn't affect builds by other events like "push",
		// since github.event.pull_request is unset so ref remains empty.
		with: {
			ref:           "${{ github.event.pull_request.head.sha }}"
			"fetch-depth": 0 // see the docs below
		}
	}

	[
		#actionsCheckout,

		// Restore modified times to work around https://go.dev/issues/58571,
		// as otherwise we would get lots of unnecessary Go test cache misses.
		// Note that this action requires actions/checkout to use a fetch-depth of 0.
		// Since this is a third-party action which runs arbitrary code,
		// we pin a commit hash for v2 to be in control of code updates.
		// Also note that git-restore-mtime does not update all directories,
		// per the bug report at https://github.com/MestreLion/git-tools/issues/47,
		// so we first reset all directory timestamps to a static time as a fallback.
		// TODO(mvdan): May be unnecessary once the Go bug above is fixed.
		json.#step & {
			name: "Reset git directory modification times"
			run:  "touch -t 202211302355 $(find * -type d)"
		},
		json.#step & {
			name: "Restore git file modification times"
			uses: "chetan/git-restore-mtime-action@075f9bc9d159805603419d50f794bd9f33252ebe"
		},

		{
			let stepName = strings.Replace(dispatchTrailer, "-", "", -1)
			json.#step & {
				name: "Try to extract \(dispatchTrailer)"
				id:   stepName
				run:  """
					x="$(git log -1 --pretty='%(trailers:key=\(dispatchTrailer),valueonly)')"
					if [[ "$x" == "" ]]
					then
					    x=null
					fi
					echo "x is $x"
					echo "value<<EOD" >> $GITHUB_OUTPUT
					echo "$x" >> $GITHUB_OUTPUT
					echo "EOD" >> $GITHUB_OUTPUT
					"""
			}
		},

		// Safety nets to flag if we ever have a Dispatch-Trailer slip through the
		// net and make it to master
		json.#step & {
			name: "Check we don't have \(dispatchTrailer) on a protected branch"
			if:   "\(isProtectedBranch) && \(containsDispatchTrailer)"
			run:  """
				echo "\(_dispatchTrailerVariable) contains \(dispatchTrailer)"
				echo "\(_dispatchTrailerVariable) value"
				cat <<EOD
				${{ \(_dispatchTrailerVariable) }}
				EOD
				echo "containsDispatchTrailer expression"
				cat <<EOD
				\(containsDispatchTrailer)
				EOD
				false
				"""
		},
	]
}

earlyChecks: json.#step & {
	name: "Early git and code sanity checks"
	run: #"""
		# Ensure the recent commit messages have Signed-off-by headers.
		# TODO: Remove once this is enforced for admins too;
		# see https://bugs.chromium.org/p/gerrit/issues/detail?id=15229
		# TODO: Our --max-count here is just 1, because we've made mistakes very
		# recently. Increase it to 5 or 10 soon, to also cover CL chains.
		for commit in $(git rev-list --max-count=1 HEAD); do
			if ! git rev-list --format=%B --max-count=1 $commit | grep -q '^Signed-off-by:'; then
				echo -e "\nRecent commit is lacking Signed-off-by:\n"
				git show --quiet $commit
				exit 1
			fi
		done

		# Ensure that commit messages have a blank second line.
		# We know that a commit message must be longer than a single
		# line because each commit must be signed-off.
		if git log --format=%B -n 1 HEAD | sed -n '2{/^$/{q1}}'; then
			echo "second line of commit message must be blank"
			exit 1
		fi

		# Ensure that the commit author is the same as the signed-off-by.  This
		# is a basic requirement of DCO. It is enforced by Gerrit (although
		# noting that in Gerrit the author name does not have to match, only
		# the email address), but _not_ by the DCO GitHub app:
		#
		#   https://github.com/dcoapp/app/issues/201
		#
		# Provide a sanity check as part of GitHub workflows that should enforce
		# this, e.g. trybot workflows.
		#
		# We do so by comparing the commit author and "Signed-off-by" trailer for
		# strict equality. Whilst this is more strict than Gerrit, it should
		# generally be the case, and we can always relax this when presented with
		# specific situations where it is is a problem.

		# commit author email address
		commitauthor="$(git log -1 --pretty="%ae")"

		# signed-off-by trailer email address. There is no way to parse just the
		# email address from the trailer in the same way as git log, so instead
		# grab the relevant trailer and then take the last whitespace-delimited
		# part as the "<>" contained email address.
		# Getting the Signed-off-by trailer in this way causes blank
		# lines for some reason. Use awk to remove them.
		commitsigner="$(git log -1 --pretty='%(trailers:key=Signed-off-by,valueonly)' | sed -ne 's/.* <\(.*\)>/\1/p')"

		if [[ "$commitauthor" != "$commitsigner" ]]; then
			echo "commit author email address does not match signed-off-by trailer"
			exit 1
		fi
		"""#
}

curlGitHubAPI: #"""
	curl -s -L -H "Accept: application/vnd.github+json" -H "Authorization: Bearer ${{ secrets.\#(botGitHubUserTokenSecretsKey) }}" -H "X-GitHub-Api-Version: 2022-11-28"
	"""#

setupGoActionsCaches: {
	// #readonly determines whether we ever want to write the cache back. The
	// writing of a cache back (for any given cache key) should only happen on a
	// protected branch. But running a workflow on a protected branch often
	// implies that we want to skip the cache to ensure we catch flakes early.
	// Hence the concept of clearing the testcache to ensure we catch flakes
	// early can be defaulted based on #readonly. In the general case the two
	// concepts are orthogonal, hence they are kept as two parameters, even
	// though in our case we could get away with a single parameter that
	// encapsulates our needs.
	#readonly:       *false | bool
	#cleanTestCache: *!#readonly | bool
	#goVersion:      string
	#os:             string

	let goModCacheDirID = "go-mod-cache-dir"
	let goCacheDirID = "go-cache-dir"

	// cacheDirs is a convenience variable that includes
	// GitHub expressions that represent the directories
	// that participate in Go caching.
	let cacheDirs = [ "${{ steps.\(goModCacheDirID).outputs.dir }}/cache/download", "${{ steps.\(goCacheDirID).outputs.dir }}"]

	let cacheRestoreKeys = "\(#os)-\(#goVersion)"

	let cacheStep = json.#step & {
		with: {
			path: strings.Join(cacheDirs, "\n")

			// GitHub actions caches are immutable. Therefore, use a key which is
			// unique, but allow the restore to fallback to the most recent cache.
			// The result is then saved under the new key which will benefit the
			// next build. Restore keys are only set if the step is restore.
			key:            "\(cacheRestoreKeys)-${{ github.run_id }}"
			"restore-keys": cacheRestoreKeys
		}
	}

	// pre is the list of steps required to establish and initialise the correct
	// caches for Go-based workflows.
	[
		// TODO: once https://github.com/actions/setup-go/issues/54 is fixed,
		// we could use `go env` outputs from the setup-go step.
		json.#step & {
			name: "Get go mod cache directory"
			id:   goModCacheDirID
			run:  #"echo "dir=$(go env GOMODCACHE)" >> ${GITHUB_OUTPUT}"#
		},
		json.#step & {
			name: "Get go build/test cache directory"
			id:   goCacheDirID
			run:  #"echo "dir=$(go env GOCACHE)" >> ${GITHUB_OUTPUT}"#
		},

		// Only if we are not running in readonly mode do we want a step that
		// uses actions/cache (read and write). Even then, the use of the write
		// step should be predicated on us running on a protected branch. Because
		// it's impossible for anything else to write such a cache.
		if !#readonly {
			cacheStep & {
				if:   isProtectedBranch
				uses: "actions/cache@v3"
			}
		},

		cacheStep & {
			// If we are readonly, there is no condition on when we run this step.
			// It should always be run, becase there is no alternative. But if we
			// are not readonly, then we need to predicate this step on us not
			// being on a protected branch.
			if !#readonly {
				if: "! \(isProtectedBranch)"
			}

			uses: "actions/cache/restore@v3"
		},

		if #cleanTestCache {
			// All tests on protected branches should skip the test cache.  The
			// canonical way to do this is with -count=1. However, we want the
			// resulting test cache to be valid and current so that subsequent CLs
			// in the trybot repo can leverage the updated cache. Therefore, we
			// instead perform a clean of the testcache.
			//
			// Critically we only want to do this in the main repo, not the trybot
			// repo.
			json.#step & {
				if:  "github.repository == '\(githubRepositoryPath)' && (\(isProtectedBranch) || github.ref == 'refs/heads/\(testDefaultBranch)')"
				run: "go clean -testcache"
			}
		},
	]
}

// isProtectedBranch is an expression that evaluates to true if the
// job is running as a result of pushing to one of protectedBranchPatterns.
// It would be nice to use the "contains" builtin for simplicity,
// but array literals are not yet supported in expressions.
isProtectedBranch: {
	#trailers: [...string]
	"((" + strings.Join([ for branch in protectedBranchPatterns {
		(_matchPattern & {variable: "github.ref", pattern: "refs/heads/\(branch)"}).expr
	}], " || ") + ") && (! \(containsDispatchTrailer)))"
}

// #isReleaseTag creates a GitHub expression, based on the given release tag
// pattern, that evaluates to true if called in the context of a workflow that
// is part of a release.
isReleaseTag: {
	(_matchPattern & {variable: "github.ref", pattern: "refs/tags/\(releaseTagPattern)"}).expr
}

checkGitClean: json.#step & {
	name: "Check that git is clean at the end of the job"
	run:  "test -z \"$(git status --porcelain)\" || (git status; git diff; false)"
}

repositoryDispatch: json.#step & {
	#githubRepositoryPath:         *githubRepositoryPath | string
	#botGitHubUser:                *botGitHubUser | string
	#botGitHubUserTokenSecretsKey: *botGitHubUserTokenSecretsKey | string
	#arg:                          _

	name: string
	run:  #"""
			\#(curlGitHubAPI) -f --request POST --data-binary \#(strconv.Quote(encjson.Marshal(#arg))) https://api.github.com/repos/\#(#githubRepositoryPath)/dispatches
			"""#
}

// dispatchTrailer is the trailer that we use to pass information in a commit
// when triggering workflow events in other GitHub repos.
//
// NOTE: keep this consistent with gerritstatusupdater parsing logic.
dispatchTrailer: "Dispatch-Trailer"

// containsDispatchTrailer returns a GitHub expression that looks at the commit
// message of the head commit of the event that triggered the workflow, an
// expression that returns true if the commit message associated with that head
// commit contains dispatchTrailer.
//
// Note that this logic does not 100% match the answer that would be returned by:
//
//      git log --pretty=%(trailers:key=Dispatch-Trailer,valueonly)
//
// GitHub expressions are incredibly limited in their capabilities:
//
//     https://docs.github.com/en/actions/learn-github-actions/expressions
//
// There is not even a regular expression matcher. Hence the logic is a best-efforts
// approximation of the logic employed by git log.
containsDispatchTrailer: {
	#type?: string
	let _typeCheck = [ if #type != _|_ {#type + "\""}, ""][0]
	"""
	(contains(\(_dispatchTrailerVariable), '\n\(dispatchTrailer): {"type":"\(_typeCheck)'))
	"""
}

containsTrybotTrailer: containsDispatchTrailer & {
	#type: trybot.key
	_
}

containsUnityTrailer: containsDispatchTrailer & {
	#type: unity.key
	_
}

_dispatchTrailerVariable: "github.event.head_commit.message"
