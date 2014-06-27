module dash.scm;

/**
 * Returns a path string to a local copy of the specified repository at the
 * given revision.
 *
 * Currently, only Git is supported.
 */
string cloneOrFetch(string url, string revision, string workDir) {
    import file = std.file;
    import git;
    import std.digest.digest;
    import std.digest.md;
    import std.path;
    import std.string;

    // Construct the directory name out of a guess for the test name and a
    // unique suffix derived from the URL.
    immutable dirName = format("%s-%s", prettyRepoName(url),
        md5Of(url).toHexString[0 .. 6]);

    // Possibly guess SCM type here in the future.

    immutable path = buildPath(workDir, dirName);

    auto repo = {
        if (file.exists(path)) {
            auto repo = openRepository(path);
            auto remote = repo.loadRemote("origin");
            remote.connect(GitDirection.fetch);
            remote.download();
            return repo;
        } else {
            return cloneRepo(url, path);
        }
    }();

    auto obj = repo.lookupObject(revision);
    GitCheckoutOptions opts;
    opts.strategy = GitCheckoutStrategy.force;
    repo.checkout(obj, opts);
    repo.setHeadDetached(obj.id);

    return path;
}

string prettyRepoName(string url) {
    import std.algorithm, std.range, std.string;

    string name = url.stripRight('/');
    name = name[name.lastIndexOf('/') + 1 .. $];

    enum ext = ".git";
    if (name.retro.startsWith(ext.retro)) {
        name.popBackN(ext.length);
    }

    return name;
}

unittest {
    import std.conv : text;
    immutable testMap = [
        "git@github.com:ldc-developers/ldc.git": "ldc",
        "https://github.com/ldc-developers/dmd-testsuite": "dmd-testsuite",
        "https://github.com/ldc-developers/dmd-testsuite.git": "dmd-testsuite",
        "../local_repo": "local_repo",
        "local_repo": "local_repo",
    ];

    static void assertEqual(T)(T a, T b) {
        import std.conv : text;
        assert(a == b, text("'", a, "' != '", b, "'."));
    }
    foreach (url; testMap.byKey) {
        assertEqual(prettyRepoName(url), testMap[url]);
    }
}
