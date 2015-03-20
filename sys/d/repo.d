/**
 * Code to manage a D component repository.
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */

module ae.sys.d.repo;

import std.algorithm;
import std.exception;
import std.file;
import std.process : environment;
import std.range;
import std.regex;
import std.string;
import std.path;

import ae.sys.git;
import ae.utils.json;
import ae.utils.regex;

/// Base class for a managed repository.
class ManagedRepository
{
	/// Git repository we manage.
	public Repository git;

	/// Should we fetch the latest stuff?
	public bool offline;

	/// Ensure we have a repository.
	public void needRepo()
	{
		assert(git.path, "No repository");
	}

	public @property string name() { needRepo(); return git.path.baseName; }

	// Head

	/// Ensure the repository's HEAD is as indicated.
	public void needHead(string hash)
	{
		needClean();
		if (getHead() == hash)
			return;

		try
			performCheckout(hash);
		catch (Exception e)
		{
			log("Error checking out %s: %s".format(hash, e));

			// Might be a GC-ed merge. Try to recreate the merge
			auto hit = mergeCache.find!(entry => entry.result == hash)();
			enforce(!hit.empty, "Unknown hash %s".format(hash));
			performMerge(hit.front.base, hit.front.branch);
			enforce(getHead() == hash, "Unexpected merge result: expected %s, got %s".format(hash, getHead()));
		}
	}

	private string currentHead = null;

	/// Returns the SHA1 of the given named ref.
	private string getRef(string name)
	{
		return git.query("rev-parse", name);
	}

	/// Return the commit the repository HEAD is pointing at.
	/// Cache the result.
	public string getHead()
	{
		if (!currentHead)
			currentHead = getRef("HEAD");

		return currentHead;
	}

	protected void performCheckout(string hash)
	{
		needClean();

		log("Checking out %s...".format(hash));

		if (offline)
			git.run("checkout", hash);
		else
		{
			try
				git.run("checkout", hash);
			catch (Exception e)
			{
				log("Checkout failed, updating and retrying...");
				update();
				git.run("checkout", hash);
			}
		}

		currentHead = hash;
	}

	/// Update the remote.
	public void update()
	{
		if (!offline)
			git.run("-c", "fetch.recurseSubmodules=false", "remote", "update", "--prune");
	}

	// Clean

	bool clean = false;

	/// Ensure the repository's working copy is clean.
	public void needClean()
	{
		if (clean)
			return;

		needRepo();

		log("Cleaning up...");
		performCleanup();

		clean = true;
	}

	private void performCleanup()
	{
		git.run("reset", "--hard");
		git.run("clean", "--force", "-x", "-d", "--quiet");
	}

	// Merge cache

	private static struct MergeInfo
	{
		string base, branch, result;
	}
	private alias MergeCache = MergeInfo[];
	private MergeCache mergeCacheData;
	private bool haveMergeCache;

	private @property ref MergeCache mergeCache()
	{
		if (!haveMergeCache)
		{
			if (mergeCachePath.exists)
				mergeCacheData = mergeCachePath.readText().jsonParse!MergeCache;
			haveMergeCache = true;
		}

		return mergeCacheData;
	}

	private void saveMergeCache()
	{
		std.file.write(mergeCachePath(), toJson(mergeCache));
	}

	private @property string mergeCachePath()
	{
		needRepo();
		return buildPath(git.path, ".git", "ae-sys-d-mergecache.json");
	}

	// Merge

	private void setupGitEnv()
	{
		string[string] mergeEnv;
		foreach (person; ["AUTHOR", "COMMITTER"])
		{
			mergeEnv["GIT_%s_DATE".format(person)] = "Thu, 01 Jan 1970 00:00:00 +0000";
			mergeEnv["GIT_%s_NAME".format(person)] = "ae.sys.d";
			mergeEnv["GIT_%s_EMAIL".format(person)] = "ae.sys.d\x40thecybershadow.net";
		}
		foreach (k, v; mergeEnv)
			environment[k] = v;
		// TODO: restore environment
	}

	/// Returns the hash of the merge between the base and branch commits.
	/// Performs the merge if necessary. Caches the result.
	public string getMerge(string base, string branch)
	{
		auto hit = mergeCache.find!(entry => entry.base == base && entry.branch == branch)();
		if (!hit.empty)
			return hit.front.result;

		performMerge(base, branch);

		auto head = getHead();
		mergeCache ~= MergeInfo(base, branch, head);
		saveMergeCache();
		return head;
	}

	private void performMerge(string base, string branch, string mergeCommitMessage = "ae.sys.d merge")
	{
		needHead(base);
		currentHead = null;

		log("Merging %s into %s.".format(branch, base));

		scope(failure)
		{
			log("Aborting merge...");
			git.run("merge", "--abort");
			clean = false;
		}

		void doMerge()
		{
			setupGitEnv();
			git.run("merge", "--no-ff", "-m", mergeCommitMessage, branch);
		}

		if (git.path.baseName() == "dmd")
		{
			try
				doMerge();
			catch (Exception)
			{
				log("Merge failed. Attempting conflict resolution...");
				git.run("checkout", "--theirs", "test");
				git.run("add", "test");
				git.run("-c", "rerere.enabled=false", "commit", "-m", mergeCommitMessage);
			}
		}
		else
			doMerge();

		log("Merge successful.");
	}

	/// Finds and returns the merge parents of the given merge commit.
	/// Queries the git repository if necessary. Caches the result.
	public MergeInfo getMergeInfo(string merge)
	{
		auto hit = mergeCache.find!(entry => entry.result == merge)();
		if (!hit.empty)
			return hit.front;

		auto parents = git.query(["log", "--pretty=%P", "-n", "1", merge]).split();
		enforce(parents.length > 1, "Not a merge: " ~ merge);
		enforce(parents.length == 2, "Too many parents: " ~ merge);

		auto info = MergeInfo(parents[0], parents[1], merge);
		mergeCache ~= info;
		return info;
	}

	/// Follows the string of merges starting from the given
	/// head commit, up till the merge with the given branch.
	/// Then, reapplies all merges in order,
	/// except for that with the given branch.
	public string getUnMerge(string head, string branch)
	{
		// This could be optimized using an interactive rebase

		auto info = getMergeInfo(head);
		if (info.branch == branch)
			return info.base;

		return getMerge(getUnMerge(info.base, branch), info.branch);
	}

	// Branches, forks and customization

	private void fetchPull(int pull)
	{
		if (offline)
			return;

		needRepo();

		log("Fetching pull request %d...".format(pull));
		git.run("fetch", "origin", "+refs/pull/%d/head:refs/remotes/origin/pr/%d".format(pull, pull));
	}

	/// Return SHA1 of the given pull request #.
	/// Fetches the pull request first, unless offline mode is on.
	string getPull(int pull)
	{
		fetchPull(pull);
		return getRef("origin/pr/%d".format(pull));
	}

	/// Return SHA1 of the given remote branch.
	/// Fetches the remote first, unless offline mode is on.
	string getRemoteBranch(string remoteName, string repoUrl, string branch)
	{
		enforce(remoteName.match(re!`^\w[\w\-]*$`), "Bad remote name");
		enforce(repoUrl.match(re!`^\w[\w\-]*:[\w/\-\.]+$`), "Bad remote URL");
		enforce(branch.match(re!`^\w[\w\-\.]*$`), "Bad branch name");

		void rm()
		{
			try
				git.run("remote", "rm", remoteName);
			catch (Exception e) {}
		}
		rm();
		scope(exit) rm();
		git.run("remote", "add", "-f", remoteName, repoUrl);

		return getRef("%s/%s".format(remoteName, branch));
	}

	/// Return SHA1 of the given GitHub fork.
	/// Fetches the fork first, unless offline mode is on.
	/// (This is a thin wrapper around getRemoteBranch.)
	string getFork(string user, string branch)
	{
		return getRemoteBranch(user, "https://github.com/%s/%s".format(user, name), branch);
	}

	// Misc

	/// Override to add logging.
	protected abstract void log(string line);
}