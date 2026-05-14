# Identity Routing

GitSetu's core magic relies on Git's native `includeIf` conditional logic. By orchestrating this built-in Git feature, GitSetu achieves directory-based identity switching without requiring any background daemons or subshell wrappers.

## The Problem

When you run `git config --global user.email "me@gmail.com"`, Git writes this value to `~/.gitconfig`. Every commit you make on your machine will now use this email address, regardless of whether you are in `~/personal` or `~/work`. 

To fix this manually, you would have to remember to run `git config user.email "dev@company.com"` inside every single work repository you ever clone. If you forget, you leak your personal email to your corporate repository.

## The GitSetu Solution

GitSetu acts as a "configuration compiler." When you run `gitsetu setup`, it generates a standalone configuration file for that specific profile.

For example, your `work` profile config (`~/.config/gitsetu/profiles/work.gitconfig`) looks like this:

```ini
[user]
    name = Aditya Kumar
    email = dev@company.com
[core]
    sshCommand = "ssh -F ~/.config/gitsetu/ssh/config.work"
```

GitSetu then injects a managed block into your global `~/.gitconfig` that tells Git: *"If the current directory is inside `~/work/`, load the `work.gitconfig` file and overwrite the global defaults."*

```ini
[includeIf "gitdir:~/work/"]
    path = ~/.config/gitsetu/profiles/work.gitconfig
```

## How It Feels

Because this is a native Git feature, the identity switch happens instantaneously the moment you `cd` into the directory.

There are no background processes watching your filesystem. There are no hooks slowing down your shell prompt. The routing is handled entirely by the C-compiled Git binary itself.

### The Global Fallback

By default, GitSetu configures `user.useConfigOnly = true` globally. This is a strict security measure. It means that if you `cd` into a repository that is *not* covered by an `includeIf` rule (e.g., `~/Downloads/random-repo`), Git will block you from committing until you explicitly set an identity.

This guarantees that you can never accidentally leak an identity. If you prefer to have a default catch-all identity, simply set a profile's directory to `~/` (your home directory).
