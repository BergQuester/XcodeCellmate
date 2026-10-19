# Claude Code in disposable macOS VMs

## Warning
While this is meant to provide isolation, this configuration is still early in development. Even with a mature config, we are dealing with LLM agents and there will alway be the possibility of the agent breaking out of it's jail. Safety is not gauranteed.

Run Claude Code against your Xcode projects inside throwaway macOS virtual machines, either as an **unattended job** or as an **attended session**, without giving it access to your Mac, your real repository, or push rights on GitHub. Each run starts from a prebuilt image in seconds, and only the commits it makes come back to you, as a branch you review before anything is built on your own machine.

The whole system is two files:

| File | What it does |
| --- | --- |
| `agent.pkr.hcl` | Packer template that builds the two VM images (Xcode layer and agent layer). |
| `agent.sh` | Builds the images, and runs jobs and sessions in disposable clones of them. |

`CLAUDE-tart-vm-section.md` holds the section to paste into your project's `CLAUDE.md`; the same text is in [Appendix A](#appendix-a-claudemd-section).

---

## Contents

1. [How it works](#1-how-it-works)
2. [Requirements](#2-requirements)
3. [Install Tart, Packer and friends](#3-install-tart-packer-and-friends)
4. [Set up the folder](#4-set-up-the-folder)
5. [Configure the template](#5-configure-the-template)
6. [Build the images](#6-build-the-images)
7. [Credentials](#7-credentials)
8. [Prepare your project](#8-prepare-your-project)
9. [Run an unattended job](#9-run-an-unattended-job)
10. [Run an attended session](#10-run-an-attended-session)
11. [Review and integrate the results](#11-review-and-integrate-the-results)
12. [Maintenance: tools, Xcode, macOS, Claude Code](#12-maintenance)
13. [Security model and its limits](#13-security-model-and-its-limits)
14. [Troubleshooting](#14-troubleshooting)
15. [Not yet verified](#15-not-yet-verified)
16. [Appendix A: CLAUDE.md section](#appendix-a-claudemd-section)

---

## 1. How it works

### Two image layers, one disposable clone per run

```
ghcr.io/cirruslabs/macos-golden-gate-xcode:27     (Cirrus Labs base: macOS 27 + Homebrew + SSH)
        │  ./agent.sh xcode <xip>     slow, rebuilt only when Xcode changes
        ▼
xcode-base     your Xcode (beta) + command line tools + iOS SDK/simulator runtime + docs
        │  ./agent.sh tools           fast, rebuilt when tools or rules change
        ▼
agent-base     Homebrew tools + non-admin "agent" user + Claude Code + git policy + deny rules
        │  ./agent.sh run / session   seconds: a copy-on-write clone, nothing installed
        ▼
job-… / session-…   throwaway VM, deleted when the run ends
```

Layering by rate of change means adding a tool doesn't reinstall Xcode, a failed tools build never touches your working images, and job VMs start without installing anything.

### How code gets in and out

Your real repository is **never mounted** into a VM. Only git bundles (single-file snapshots of git history) cross the boundary, so nothing the agent does to git hooks or config can execute on your Mac.

```
Your Mac                                         Throwaway VM (user "agent")
────────                                         ───────────────────────────
repo @ branch ──git bundle──► in.bundle ──scp──► ~/work (clone) on agent/<run-name>
                                                     │  Claude Code works, commits
your repo ◄──git fetch── out.bundle ◄──scp───────── new commits only
  branch agent/<run-name> (not checked out)
```

- **In:** only the *committed* history of the starting branch. Uncommitted changes in your repo stay behind (the script warns you).
- **Out:** only commits on the run's branch. When a run ends (normally or with Ctrl-C), leftover uncommitted changes in the VM become a `WIP:` commit (sessions ask first), the new commits are bundled and fetched into your repo as `agent/<run-name>`, and the VM is deleted. Your checked-out branch and working files are never touched.

---

## 2. Requirements

- **An Apple silicon Mac.** Tart uses Apple's Virtualization framework, which runs macOS guests only on Apple silicon.
- **A host macOS at least as new as the guest.** The images here are macOS 27; running a macOS 27 guest very likely requires a macOS 27 host.
- **Disk space:** plan on roughly 250 GB free. The base image is large, `xcode-base` is resized to a 200 GB disk (sparse, so it uses less), and Xcode unpacks to tens of GB.
- **Memory:** each VM is given 16 GB and 8 CPUs by default (adjustable, see [§5](#5-configure-the-template)).
- **An Apple Developer account** to download Xcode (including betas) from <https://developer.apple.com/download/>.
- **A Claude subscription (Pro, Max, Team or Enterprise) or an Anthropic API key** for Claude Code (see [§7](#7-credentials)).
- **A GitHub fine-grained personal access token** with read-only permissions (see [§7](#7-credentials)).
- **`jq` on your Mac** for the audit reports (`brew install jq`; recent macOS versions also include it at `/usr/bin/jq`).
- **An SSH key pair** on your Mac (`~/.ssh/id_ed25519.pub` by default). Create one with `ssh-keygen -t ed25519` if you don't have it.

Apple's macOS license, enforced by the Virtualization framework, allows at most **two macOS VMs running at once** per Mac. That means two jobs/sessions at a time, or one while an image build is running.

---

## 3. Install Tart, Packer and friends

Install [Homebrew](https://brew.sh) if you don't have it, then:

```sh
# Tart (the formula moved from cirruslabs/cli to openai/tools after Cirrus Labs joined OpenAI)
brew install openai/tools/tart

# Packer, from HashiCorp's tap
brew tap hashicorp/tap
brew install hashicorp/tap/packer

# Optional: list available image tags from the registry
brew install crane
```

Check them:

```sh
tart --version
packer version
```

You don't need to install the Tart Packer plugin yourself: `agent.sh` runs `packer init`, which downloads it.

### Grant your terminal Local Network access

macOS blocks apps from connecting to devices on the local network until you allow it, and the VMs count. Without this, connections to the VM fail with **`No route to host`** and Packer waits forever at "Waiting for SSH".

Open **System Settings → Privacy & Security → Local Network** and turn on the app you run these scripts from (Terminal, iTerm, Warp, VS Code…). Quit and reopen it afterwards. Repeat for any other app you later run `agent.sh` from.

### Softnet (network isolation for runs)

Jobs and sessions start VMs with Tart's `--net-softnet`, which isolates them from your local network. Softnet needs either its binary set SUID root or passwordless `sudo`, so expect to set that up the first time you run a job; check `tart run --help` and Tart's documentation for the exact steps on your version. If you want to get going without it, remove `--net-softnet` from the two `tart run` lines in `agent.sh` (and accept that the VM can then reach your LAN).

### Apple's `container` tool

If you also use Apple's `container` CLI, stop its service while using Tart (`container system stop`); both use the same virtual networking and can interfere.

---

## 4. Set up the folder

Put the files in a folder of their own, for example `~/tartvmconfigs`:

```
tartvmconfigs/
├── agent.sh
├── agent.pkr.hcl
├── CLAUDE-tart-vm-section.md
└── README.md
```

```sh
cd ~/tartvmconfigs
chmod +x agent.sh
./agent.sh            # prints usage
```

Run every command in this README from that folder.

---

## 5. Configure the template

All the settings you're expected to change are at the top of `agent.pkr.hcl`, under `settings you edit`:

| Setting | Default | Notes |
| --- | --- | --- |
| `base_image` | `ghcr.io/cirruslabs/macos-golden-gate-xcode:27` | The starting image. Pin it by digest (`…@sha256:…`) for reproducible builds; see [§12](#12-maintenance). |
| `sdk_platforms` | empty (= latest iOS) | Simulator runtimes installed with Xcode; see [§6.4](#64-choose-sdk-platforms-and-versions). Can be overridden per build on the command line. |
| `brew_packages` | `gh`, `jq`, `xcbeautify` | Homebrew packages installed in the agent layer. |
| `claude_deny_rules` | git/`gh` writes, web and network tools, nested `claude`, signing, `sudo`, Homebrew, version and package managers | Claude Code deny rules, written to root-owned managed settings, grouped by category. Remove the `pod`/`bundle`/`npm` rules if a project needs them. See [§13](#13-security-model-and-its-limits). |
| `ssh_pubkey_path` | `~/.ssh/id_ed25519.pub` | The only key that can log in to job VMs as `agent`. |

VM sizes are set in the two `source` blocks: `cpu_count`, `memory_gb` and `disk_size_gb` in `source "tart-cli" "xcode"`, and `cpu_count`/`memory_gb` in `source "tart-cli" "agent"` (which sizes every job and session VM).

> **Editing the scripts inside `agent.pkr.hcl`:** in the `<<-EOT` blocks, write shell variables as `$VAR`, never `${VAR}`. Packer treats `${…}` as its own placeholders; write `$${VAR}` if you need the braces.

---

## 6. Build the images

### 6.1 Download Xcode

Download the Xcode `.xip` you want (a release or a beta) from <https://developer.apple.com/download/> and leave it where it is, for example `~/Downloads/Xcode_27.2_beta_3.xip`. The build reads it directly from there through a read-only shared folder, so don't move or delete it until the build finishes.

### 6.2 Set the VM admin password

The build replaces the base image's default `admin`/`admin` login with a password you choose. Set it without leaving it in your shell history:

```sh
read -rs PKR_VAR_admin_password && export PKR_VAR_admin_password
```

Type the password and press Enter (nothing is shown). Keep it in your password manager; you need it to log in to a VM as `admin`. The variable lasts only for this Terminal window.

### 6.3 Build both layers

```sh
./agent.sh xcode ~/Downloads/Xcode_27.2_beta_3.xip
```

What happens:

1. **Base image download.** The first run pulls the Cirrus Labs image from GHCR (tens of GB).
2. **VM boot and SSH.** Packer clones it to `xcode-base-next`, resizes the disk, boots it and waits for SSH. A VM window opens. One to three minutes is normal.
3. **Xcode install** (15–30+ minutes, little output). The `.xip` is expanded, moved to `/Applications/<xip name>.app`, every other Xcode is removed, `/Applications/Xcode.app` is symlinked to it, it's selected with `xcode-select` (which also provides the command line tools), the license is accepted and first-launch setup runs.
4. **Simulator runtimes.** All existing runtimes are deleted, then the platforms you asked for are installed (by default, the latest iOS runtime for this Xcode; several GB each). The SDKs themselves ship inside Xcode. See [§6.4](#64-choose-sdk-platforms-and-versions).
5. **Documentation (manual step).** Packer pauses with a note. In the VM window, open Xcode. If its *Components* sheet appears, click **Download & Install** (iOS is already installed, so it should finish quickly). Then open **Xcode → Settings → Components** and download **Documentation** if it's offered. Quit Xcode, return to the Terminal, and press **Enter**.
6. **Checks.** The Xcode version, iOS SDK version and installed runtimes are printed. Confirm they're what you expect.
7. **Swap.** `xcode-base-next` replaces `xcode-base`.
8. **Agent layer** (a few minutes, automatic): Homebrew packages, the non-admin `agent` user with your SSH key and automatic login, Claude Code, git identity and push backstop, Claude Code deny rules (printed as JSON so you can check them), and finally the admin password change. `agent-base-next` then replaces `agent-base`.

Confirm the result:

```sh
tart list        # shows xcode-base and agent-base
```

### 6.4 Choose SDK platforms and versions

By default the image gets the latest iOS simulator runtime for the Xcode you install. To choose others, list them after the `.xip`:

```sh
./agent.sh xcode ~/Downloads/Xcode_27.2_beta_3.xip iOS watchOS                # latest iOS and watchOS
./agent.sh xcode ~/Downloads/Xcode_27.2_beta_3.xip iOS "iOS 26.4"            # latest iOS plus iOS 26.4
./agent.sh xcode ~/Downloads/Xcode_27.2_beta_3.xip iOS iphonesimulator_22A3351.dmg   # plus an imported image
```

or set a permanent default in `sdk_platforms` in `agent.pkr.hcl` (command-line arguments override it):

```hcl
default = ["iOS", "iOS 26.4", "watchOS"]
```

Each entry is one of:

| Entry | Installs |
| --- | --- |
| `iOS`, `watchOS`, `tvOS`, `visionOS` | The latest runtime of that platform for this Xcode (`xcodebuild -downloadPlatform`). |
| `iOS 26.4` (platform and version or build number) | That specific runtime (`-buildVersion`). If the plain download fails, it's retried with `-architectureVariant arm64`, which some versions require. |
| `something.dmg` | A runtime disk image imported with `xcodebuild -importPlatform`. Put the file in the same folder as the `.xip`. |

Quote entries containing spaces. An empty list means latest iOS. The SDKs for every platform come with Xcode; this only controls which **simulator runtimes** are installed. Only what you list is installed, so include `iOS` if you add other platforms and still want the latest iOS.

**Older runtimes.** Xcode 27's `xcodebuild` has been reported to refuse runtimes older than iOS 26 ("iOS 18.6 is not available for download") even though Xcode's *Components* pane can still add them. If an entry fails, the build stops with a message. Remove it and add that platform by hand at the documentation pause (**Xcode → Settings → Components**, then add the platform), or export a `.dmg` on a Mac with an older Xcode (`xcodebuild -downloadPlatform iOS -buildVersion 18.6 -exportPath ~/runtimes`) and import that.

Keep the Terminal window open for the whole build; closing it stops Packer. If a build fails or you stop it, just rerun the same command: it deletes the half-built `-next` image and starts again, and your existing images are untouched.

---

## 7. Credentials

Jobs and sessions need two things in the Terminal you run them from: a **Claude credential** (a subscription token *or* an API key) and a **GitHub token**.

### Claude: subscription token (Pro, Max, Team, Enterprise)

To use your Claude subscription instead of paying per token, generate a long-lived token on your Mac:

```sh
claude setup-token
```

It walks you through a browser sign-in and prints a token valid for one year. It isn't saved anywhere, so copy it into the Keychain (below). The token only grants inference (it can't start Remote Control sessions). See [Authentication](https://code.claude.com/docs/en/authentication) in the Claude Code docs.

```sh
export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-…
```

Things to know:

- **Runs count against your plan's usage limits**, shared with your normal Claude use. Long unattended jobs can use a lot; if you hit a limit mid-job, the job stops making progress until the limit resets.
- **Auto mode** (used by `agent.sh run`) is available on Max, Team and Enterprise, but not on every plan or model; if a job's log shows nearly every command denied, auto mode wasn't available (see [§14](#14-troubleshooting)).
- **Treat the token like a password for your subscription.** Anyone who gets it can use your plan for a year. It's exposed inside the VM during runs, so the protections in [§13](#13-security-model-and-its-limits) apply to it too. If it leaks, look in your Claude account settings for a way to revoke it (or contact support), and generate a new one.
- In an attended session, Claude Code may show its first-run setup screens (theme and so on) because each VM is fresh. Click through them.

### Claude: API key (pay per token)

```sh
export ANTHROPIC_API_KEY=sk-ant-…
```

Use a key from the [Claude Console](https://console.anthropic.com/) dedicated to this purpose, with a spend limit. Treat it as exposed to the VM.

### Which one is used

If `CLAUDE_CODE_OAUTH_TOKEN` is set, `agent.sh` passes only that into the VM; otherwise it passes `ANTHROPIC_API_KEY`. Only one is ever passed, because Claude Code prefers an API key over a subscription token when both are present. The script prints `Claude auth: …` at the start of each run so you can see which.

### GitHub token: read-only, fine-grained

The read-only permission on this token is what **actually** prevents pushes; the other push blocks are backups. Create it at **GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens**:

- **Repository access:** only the repositories the agent needs, including any private Swift package dependencies.
- **Permissions:** *Contents: Read-only* (metadata read is added automatically). Add *Issues: Read-only* and/or *Pull requests: Read-only* only if your jobs read them.
- **Expiration:** short, and rotate it.

```sh
export GH_TOKEN=github_pat_…
```

### Keep them out of your shell history

Store both in the macOS Keychain once:

```sh
security add-generic-password -a "$USER" -s agent-claude-oauth -w   # prompts for the setup-token
security add-generic-password -a "$USER" -s agent-anthropic -w      # or: prompts for the API key
security add-generic-password -a "$USER" -s agent-github -w         # prompts for the GitHub token
```

and load them when needed:

```sh
export CLAUDE_CODE_OAUTH_TOKEN="$(security find-generic-password -a "$USER" -s agent-claude-oauth -w)"
# or: export ANTHROPIC_API_KEY="$(security find-generic-password -a "$USER" -s agent-anthropic -w)"
export GH_TOKEN="$(security find-generic-password -a "$USER" -s agent-github -w)"
```

Inside the VM the values are written to `~/.job-env`, readable only by `agent`, and disappear with the VM.

---

## 8. Prepare your project

### 8.1 Add the VM section to `CLAUDE.md`

Paste [Appendix A](#appendix-a-claudemd-section) (or `CLAUDE-tart-vm-section.md`) into your repository's `CLAUDE.md`. It only takes effect inside these VMs: the script sets `TART_AGENT_VM=1`, and the section tells Claude to ignore it otherwise, so it's safe to keep in the normal file. Auto mode's safety classifier reads `CLAUDE.md` too, so these rules steer its decisions as well as Claude's.

It tells Claude to: commit early and often (only commits survive), stay on its branch, never push, never clone other repositories, not use the web or SSH, build with `CODE_SIGNING_ALLOWED=NO`, format the project file, leave build scripts, dependencies and signing alone unless asked, keep credentials secret, treat classifier blocks as signals, and finish with a summary.

### 8.2 Add your project's specifics

Below the VM section, add what an agent needs to work on *your* project without guessing:

````markdown
## Building and testing this project

- Scheme: `MyApp`
- Build: `xcodebuild -scheme MyApp -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO build | xcbeautify`
- Test:  `xcodebuild -scheme MyApp -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO test | xcbeautify`
- Lint/format: …
- Code style and conventions: …
- Areas not to touch: …
````

Check the simulator names available in the image by opening a session and running `xcrun simctl list devices available`.

### 8.3 Commit it on the branch you'll start from

The VM receives only committed history, so commit `CLAUDE.md` (and any other setup) on the branch you'll pass to `agent.sh` before running.

### 8.4 Check `.gitignore`

Leftover changes at the end of a run are committed as `WIP:` **including untracked files**. Make sure in-repo build output (for example `.build/`, `DerivedData/` if you keep it in the repo, `*.xcresult`) is ignored, so it doesn't end up in those commits.

---

## 9. Run an unattended job

### 9.1 Write the prompt file

The prompt file is the agent's whole briefing; it can't ask you anything mid-job. Good prompts include:

- The task and what "done" looks like (acceptance criteria, tests that should pass).
- Pointers to the relevant files or types.
- Constraints specific to this job ("don't change the public API", "keep iOS 18 support").
- A reminder to commit after each working step (the `CLAUDE.md` section covers this, but it doesn't hurt).

Example `job.md`:

```markdown
Add pull-to-refresh to `FeedView` that calls `FeedModel.reload()`.

Done when:
- Pulling down on the feed triggers a reload and shows the system refresh indicator.
- `FeedModelTests` has a test covering reload being called.
- The app builds and all tests pass on the iPhone 17 simulator.

Don't change `FeedModel`'s public API.
```

### 9.2 Run it

```sh
./agent.sh run ~/src/MyApp job.md              # starts from your current branch
./agent.sh run ~/src/MyApp job.md develop      # or from a named branch
./agent.sh run --gui ~/src/MyApp job.md        # with the VM window shown
```

### 9.3 What happens

1. The starting branch is bundled into `~/agent-jobs/job-<date>-<time>/in.bundle`.
2. `agent-base` is cloned to `job-…` and booted headless (or with its window, with `--gui`) on Softnet.
3. The bundle, the prompt and the credentials are copied in. The VM clones the bundle to `~/work`, creates branch `agent/job-…`, and points `origin` at your GitHub repository for fetching only (its push URL is set to `PUSH-DISABLED`).
4. Claude Code runs `claude -p "<prompt>" --permission-mode auto` in `~/work` until it decides it's done. There's no time limit.
5. Leftover changes become a `WIP:` commit, new commits are bundled and fetched into your repo as `agent/job-…`, and the VM is deleted.

Pressing **Ctrl-C** also goes through step 5, so work committed so far is kept.

### 9.4 Watching and output

Jobs run with `--output-format stream-json`, so the Terminal shows Claude's messages and each tool call as they happen. Everything is saved in `~/agent-jobs/job-…/`:

| File | Contents |
| --- | --- |
| `prompt.md` | The prompt it ran with. |
| `agent.log` | A readable log: Claude's messages, each tool call (`→`), errors (`✗`), and the final summary. |
| `events.stream.jsonl` | Claude Code's raw event stream for the job (`--output-format stream-json`). |
| `audit.jsonl` | Every tool call and result, captured live from the VM's audit hook. |
| `denials.md` / `calls.json` | The denied and failed calls report ([§11.7](#117-review-denied-and-failed-commands-and-tune-the-rules)) and its data. |
| `in.bundle` / `out.bundle` | What went in and what came out. |
| `tart.log` | The VM's own log. |

---

## 10. Run an attended session

```sh
./agent.sh session ~/src/MyApp                 # from your current branch
./agent.sh session ~/src/MyApp develop         # or from a named branch
./agent.sh session --gui ~/src/MyApp           # with the VM window shown
```

You land in Claude Code, running in the VM in `~/work` on branch `agent/session-…`, in your Terminal. Claude starts in your default permission mode (auto mode on current versions; Shift+Tab switches). The script sets `AGENT_ATTENDED=1`, so the `CLAUDE.md` section lets Claude ask you questions; all the other rules still apply.

- Quitting Claude leaves you in a shell in `~/work`, where you can run `git log`, `xcodebuild`, or `claude` again.
- Exiting that shell ends the session. If there are uncommitted changes, they're listed and you're asked `Keep them as a WIP commit? [Y/n]`. Then the commits are fetched into your repo and the VM is deleted. Afterwards, `~/agent-jobs/session-…/denials.md` lists any denied or failed tool calls ([§11.7](#117-review-denied-and-failed-commands-and-tune-the-rules)).

### Watching the Simulator (`--gui`)

With `--gui`, the VM window shows the `agent` user's desktop (the image logs `agent` in automatically). Run `open -a Simulator` in the VM shell, or ask Claude to, to watch simulator runs.

- **Don't close the VM window**: that shuts the VM down before your commits are collected. End the session from the Terminal.
- On a new account's first login macOS may show setup screens (Apple Account, Siri…). They don't affect Claude, which works over SSH; see [§14](#14-troubleshooting).

### Continuing earlier work

Start a job or session from an agent branch to build on it:

```sh
./agent.sh session ~/src/MyApp agent/job-20261018-101500
```

The new run gets its own branch on top of it.

---

## 11. Review and integrate the results

Every run leaves a branch `agent/<run-name>` in your repository. Nothing is merged, checked out or pushed for you.

If the agent's commits change any file that defines its own limits (`CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md`, `GEMINI.md`, `.claude/`, `.mcp.json`, `.cursorrules`, `.cursor/`, `.github/copilot-instructions.md`, `.github/instructions/`), the script prints **BLOCKED**, lists the files, and puts the commits on `agent-quarantine/<run-name>` instead, with the list saved to `~/agent-jobs/<run>/PROTECTED-FILES-CHANGED.txt`. Inspect them; if you decide the rest of the work is good, cherry-pick the commits you want and drop the limit-file changes. The patterns live in `PROTECTED_RE` near the top of `agent.sh`.

### 11.1 Read what it did

```sh
cd ~/src/MyApp
git log --stat main..agent/job-…        # the commits, with files changed
git diff main...agent/job-…             # the full change (three dots: since the branch point)
cat ~/agent-jobs/job-…/agent.log        # Claude's summary and notes
```

Use whatever diff tool you prefer: `git difftool`, Xcode's source control navigator, GitHub Desktop, Tower, Fork, etc.

### 11.2 Check these before building on your Mac

Building in Xcode on your Mac is the first time the agent's code runs outside a VM. Look closely at changes to:

- **The project file** (`*.xcodeproj/project.xcproj`): Run Script build phases, build rules, new targets.
- **Schemes** (`*.xcscheme`): pre/post actions.
- **Dependencies**: `Package.swift`, `Package.resolved`, newly added packages (package plugins and macros run during builds; Xcode will ask you to trust new ones, so read what you're trusting).
- **Signing and entitlements**: `*.entitlements`, signing settings, provisioning.
- **Automation and config**: CI workflows (`.github/`), `.claude/` settings, scripts, Makefiles, git hooks configs.
- **Tests**: deleted or weakened tests and assertions.
- **`WIP:` commits**: untracked files that shouldn't be in the repo.

### 11.3 Build and test it yourself

```sh
git switch agent/job-…
# open in Xcode, build and run the tests
```

or check it out in a separate worktree so your current work isn't disturbed:

```sh
git worktree add ../MyApp-review agent/job-…
```

### 11.4 Integrate

Pick the history you want:

```sh
git switch main
git merge --no-ff agent/job-…        # keep the agent's commits as-is
git merge --squash agent/job-…       # one commit; then: git commit
git cherry-pick <commit>…            # just some of them
git rebase -i main agent/job-…       # tidy commits first, then merge
```

Then push and open a pull request **from your Mac**, with your own credentials, as you normally would.

### 11.5 Ask for changes

Start a new job or session from the agent branch with a prompt describing the fixes ([§10](#continuing-earlier-work)).

### 11.6 Clean up

```sh
git branch -D agent/job-…                   # after merging or rejecting
rm -rf ~/agent-jobs/job-…                   # logs and bundles you no longer need
git worktree remove ../MyApp-review         # if you used one
```

`~/agent-jobs` is your audit trail; keep it as long as it's useful.

### 11.7 Review denied and failed commands, and tune the rules

Every tool call in the VM is recorded, so you can see what the restrictions blocked, what failed, and what the agent did instead, then decide whether to loosen a rule (it blocked legitimate work) or tighten one (the agent tried to get around it).

**How it's recorded.** The image's managed settings run an audit hook, `/usr/local/libexec/agent-audit`, on every `PreToolUse`, `PostToolUse`, `PostToolUseFailure` and `PermissionDenied` event. It appends Claude Code's JSON for each event to `~/.agent-audit/events.jsonl` in the VM. While the run is going, `agent.sh` follows that file over SSH and saves each line on your Mac as `audit.jsonl` the moment it's written, so lines can't be changed afterwards. At the end it also fetches the VM's own copy (`audit.vm.jsonl`) and, if that has fewer lines than were captured live, the report warns that the log was truncated or replaced. Jobs additionally keep Claude Code's own event stream (`events.stream.jsonl`), whose final result lists every permission denial; sessions bring back their transcripts (`transcripts/`) instead. Both supply Claude's messages for the report.

Commands are kept complete. The only change is that the exact values of the Claude credential and the GitHub token are replaced with `[REDACTED:…]` in everything saved on your Mac.

**The per-run report.** When a run ends, `agent.sh` prints a one-line count and writes `~/agent-jobs/<run>/denials.md`. For every call that wasn't successful it shows:

- the status: **denied** (by a deny rule or auto mode, with the reason when Claude Code gives one), **blocked** (started but never produced a result, usually a deny rule), **failed** (ran and returned an error) or **interrupted**;
- the matching deny rule from `claude_deny_rules`, so you know exactly which line to change;
- the complete command (or, for file edits, the complete tool input);
- what Claude said just before it;
- **What it did next:** the following calls, with their complete commands, statuses and Claude's messages, until one succeeded (at most five);
- a **Possible workaround attempt** flag when another call was blocked right after a denial, for example `python3` denied, then `perl`, then a script.

**Across runs.** `./agent.sh denials` groups every denied and failed call from all runs that have a report, by matching rule (or, for failures, by command), with counts, the number of runs affected and example commands. It also saves the summary to `~/agent-jobs/DENIALS.md`.

**Acting on it.**

- A rule that keeps blocking legitimate work: remove or narrow it in `claude_deny_rules` in `agent.pkr.hcl`, then `./agent.sh tools`.
- A workaround chain: add rules for the routes it tried, and consider a line in your `CLAUDE.md` explaining the expected way to do that task.
- Repeated failures of the same command (a missing tool, a wrong simulator name): fix the environment (`brew_packages`, `sdk_platforms`) or your project's `CLAUDE.md` instructions.

The matching rule is found by applying your current `claude_deny_rules` to the recorded command, so if you change the rules later, older reports keep the rule names from when they were generated. Calls made by the build itself (build phases, package plugins) aren't tool calls and aren't recorded.

---

## 12. Maintenance

### Add a tool or change deny rules

Edit `brew_packages` or `claude_deny_rules` in `agent.pkr.hcl`, then:

```sh
read -rs PKR_VAR_admin_password && export PKR_VAR_admin_password
./agent.sh tools
```

This rebuilds only the agent layer, in a few minutes. Any change to the agent-layer setup (the `agent` build block) needs the same command.

### Update Xcode

Download the new `.xip`, then:

```sh
./agent.sh xcode ~/Downloads/Xcode_27.3_beta_1.xip
```

This rebuilds both layers, including the manual documentation step. Add platform arguments to change the simulator runtimes ([§6.4](#64-choose-sdk-platforms-and-versions)). To be able to roll back, copy the current image first:

```sh
tart clone xcode-base xcode-base-27.2b3
```

To roll back, restore that copy (`tart delete xcode-base && tart clone xcode-base-27.2b3 xcode-base`) and run `./agent.sh tools`.

### Update macOS

Don't run Software Update inside the VMs: updates in these VMs are unreliable and can stall, partly because the disk resize affects the recovery partition the updater relies on. Instead, take the new macOS from a newer base image:

1. Look for a newer tag or digest of the base image, at <https://github.com/cirruslabs/macos-image-templates/pkgs/container/macos-golden-gate-xcode> or with `crane ls ghcr.io/cirruslabs/macos-golden-gate-xcode`. Cirrus rebuilds its images regularly.
2. Set `base_image` in `agent.pkr.hcl` to it, ideally by digest: `ghcr.io/cirruslabs/macos-golden-gate-xcode@sha256:…`.
3. Run `./agent.sh xcode <your .xip>`.

### Update Claude Code

Claude Code is installed when the agent layer is built. Rebuild periodically (`./agent.sh tools`) to pick up new versions.

### Disk space

`tart list` shows images and sizes. Delete what you don't need with `tart delete <name>`. Downloaded registry images are cached by Tart; `tart prune` cleans its caches (check `tart prune --help`).

---

## 13. Security model and its limits

### Layers of protection

| Layer | Protects against |
| --- | --- |
| **Throwaway VM** per run | Damage to your Mac; anything persisting between runs. |
| **Git bundles instead of mounts** | The agent touching your real repository, or planting git hooks/config that run on your Mac. |
| **Non-admin `agent` user**, key-only SSH | System-level changes inside the VM; the admin password is never given to the agent. |
| **Read-only GitHub token** | Pushes, PRs, comments, any write to GitHub. This is the real push guarantee. |
| **Disabled push URL and `pre-push` hook** | Accidental pushes (backup only: the agent could undo these). |
| **Claude Code deny rules** in root-owned managed settings | Pushing, cloning, changing remotes or the agent branch; `gh` writes and `gh api`; web and network tools; nested `claude`; non-Xcode languages and nested shells (`python3`, `node`, `ruby`, `perl`, `bash`/`sh`/`zsh`, `env`, `eval`, `source`, `./*.sh`…); editing the files that define its limits (`CLAUDE.md`, `AGENTS.md`, `.claude/`, `.mcp.json`, `~/.claude/`, `~/.job-env`, git and shell config…); signing and distribution; `sudo`; Homebrew; version managers; package managers other than SwiftPM. Highest precedence, apply in every permission mode, and the agent can't edit them. |
| **Auto mode** | A classifier reviews risky actions before they run, including sending data to external endpoints and download-and-execute, and isn't influenced by the contents of files and pages Claude reads. |
| **Softnet** | The VM reaching your local network. |
| **`CLAUDE.md` rules** | Steering Claude (and the classifier) away from pushing, cloning, web/SSH, build-script and dependency changes. |
| **Quarantine of limit-file changes** (in `agent.sh`) | Commits that touch `CLAUDE.md`, `AGENTS.md`, `.claude/`, `.mcp.json` or other agents' instruction files are put on `agent-quarantine/<run>` instead of `agent/<run>`, even if made through the shell. |
| **Audit log** (hook in managed settings, captured live by `agent.sh`) | Unnoticed denials, failures and workaround attempts: every tool call is recorded where the agent can't rewrite what's already captured ([§11.7](#117-review-denied-and-failed-commands-and-tune-the-rules)). |
| **Your review** before building on your Mac | Malicious or broken code, build scripts, dependencies, signing changes. |

### What's still exposed

- **Inside the VM, during a run:** your source code, the Claude credential (subscription token or API key) and the GitHub token. The VM has internet access (Claude Code needs Anthropic's API, and git/xcodebuild need GitHub), so a determined or prompt-injected agent could try to send them out. Auto mode and the deny rules make this much harder, not impossible. Use a dedicated API key with a spend limit (or keep the subscription token's exposure in mind) and a short-lived, narrowly scoped GitHub token.
- **Deny rules match commands as written.** `python3 -c 'import urllib…'`, `/usr/bin/curl`, or a script containing `git push` won't match. They're a backstop.
- **Auto mode reduces risk but isn't a guarantee.** The classifier can still allow a risky action, which is why Anthropic recommends running it in isolated environments like these VMs.
- **Network-level filtering isn't set up by default.** See [Optional: allowlist network access from your Mac](#optional-allowlist-network-access-from-your-mac) for enforcing it on your Mac with a proxy and a host firewall.
- **`xcode-base` keeps the default `admin`/`admin` password.** It never runs jobs and stays on your Mac, but don't share or push it to a registry.
- **Xcode betas** are pre-release software running agent-written code; that's another reason the review step matters.

### Optional: allowlist network access from your Mac

Everything above still lets the VM reach the whole internet; it only makes it hard for the agent to *try*. This section describes how to enforce, on your Mac, that a VM can reach only Claude and GitHub, using a host firewall such as [Little Snitch](https://www.obdev.at/products/littlesnitch/) or [LuLu](https://objective-see.org/products/lulu.html). It's a manual setup: `agent.sh` doesn't configure it for you.

#### Why the firewall can't simply watch the VM

Little Snitch and LuLu are *application* firewalls: they filter connections made by processes on your Mac, through Apple's Network Extension framework. A Tart VM's traffic isn't made by a process. It leaves through Apple's virtual network (vmnet), which forwards and translates the VM's packets below the level these firewalls see. Reports from other VM products match this: Little Snitch saw guest traffic only when a user-space helper process did the NAT (Parallels' `prl_naptd`, VMware in NAT mode), and not in bridged mode.

So expect your firewall **not** to see Tart VM traffic at all. Check on your own Mac before relying on anything (see *Test it*, below): if Little Snitch does show the VM's connections under some process, you can write rules for that process directly and skip the proxy.

#### The design: a proxy on your Mac, filtered by the firewall

Give the firewall a process to watch:

```
VM (Claude Code, git, gh) ──HTTPS_PROXY──► proxy on your Mac ──► internet
         │                                   ▲
         └─ Softnet: everything else blocked │ Little Snitch / LuLu: proxy may only
            (only the proxy is reachable)    │ reach api.anthropic.com, github.com, …
```

1. A small HTTP proxy runs on your Mac (this guide uses [tinyproxy](https://tinyproxy.github.io/)).
2. Inside the VM, Claude Code, `git` and `gh` are told to use it. All three honour `HTTPS_PROXY`; git over SSH is tunnelled through it too.
3. Softnet blocks the VM from everything except the proxy, so tools that ignore the proxy simply fail (fail closed).
4. Little Snitch (or LuLu) has rules for the proxy process: allowed to reach only the listed domains, denied everything else. Its monitor shows every connection each run made, by domain name.

The proxy's own host filter is a second layer, so the allowlist doesn't depend on a single tool.

#### What to allow

| Domain | Port | Used by |
| --- | --- | --- |
| `api.anthropic.com` | 443 | Claude Code (API key or subscription token), including auto mode's classifier |
| `github.com` | 443 | git over HTTPS, Swift packages |
| `ssh.github.com` | 443 | git over SSH, tunnelled through the proxy |
| `api.github.com` | 443 | `gh` (reading issues and PRs) |
| `codeload.github.com` | 443 | Swift package archives |
| `objects.githubusercontent.com` | 443 | release assets, some package downloads (add if fetches fail) |

Start with this list and watch the firewall's log on the first runs: a blocked connection shows exactly which name to add. Anthropic also publishes the fixed address range its API receives connections on (`160.79.104.0/23`, see [IP addresses](https://docs.anthropic.com/en/api/ip-addresses)) if you'd rather allow it by address.

#### Step 1: install and configure the proxy

```sh
brew install tinyproxy
```

Find the address of your Mac on the VM network: start any VM, then on your Mac run `ifconfig | grep -A3 bridge1`. The `inet` address (for example `192.168.64.1` or `192.168.65.1`) is the gateway VMs see. The bridge only exists while a VM runs, so the proxy listens on all addresses but only accepts clients from the VM range.

Create `/opt/homebrew/etc/tinyproxy/allowed-hosts` with one pattern per line:

```
^api\.anthropic\.com$
^github\.com$
^ssh\.github\.com$
^api\.github\.com$
^codeload\.github\.com$
^objects\.githubusercontent\.com$
```

Edit `/opt/homebrew/etc/tinyproxy/tinyproxy.conf` so it contains (keep the file's other defaults):

```
Port 8888
Listen 0.0.0.0
Allow 192.168.64.0/22          # Tart/vmnet VM addresses only
ConnectPort 443                # HTTPS and SSH-over-443 only
Filter "/opt/homebrew/etc/tinyproxy/allowed-hosts"
FilterType ere
FilterDefaultDeny Yes          # anything not listed is refused
LogLevel Connect
```

Start it, and check it's listening:

```sh
brew services start tinyproxy
lsof -nP -iTCP:8888 -sTCP:LISTEN
```

Check the directive names against `man tinyproxy.conf` for your version; option names have changed between releases.

#### Step 2: firewall rules for the proxy

**Little Snitch:** create a rule group (for example "Agent VM proxy") with:

- **Allow** outgoing connections from `/opt/homebrew/opt/tinyproxy/bin/tinyproxy` (check the path with `brew --prefix tinyproxy`) to each domain in the table, port 443.
- **Deny** outgoing connections from the same process to any other destination.

Little Snitch evaluates more specific rules first, so the per-domain allows win over the catch-all deny. Then open the Network Monitor and filter on `tinyproxy` to watch runs.

**LuLu:** add the tinyproxy binary with *Block* as the default, then allow rules for each domain on port 443.

#### Step 3: point the VM at the proxy

These lines go in the VM's job environment. In `agent.sh`, add them to the `printf` that writes `~/.job-env` (replace `192.168.64.1` with your gateway address):

```sh
export HTTPS_PROXY=http://192.168.64.1:8888
export HTTP_PROXY=http://192.168.64.1:8888
export NO_PROXY=localhost,127.0.0.1
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1   # no telemetry or error reporting
export DISABLE_AUTOUPDATER=1                        # no update checks
```

`gh` and Claude Code read `HTTPS_PROXY`; so does git for HTTPS remotes. For git over SSH, add this to the image (in the `agent` build's git setup), which sends SSH to GitHub through the proxy on port 443:

```
# /Users/agent/.ssh/config
Host github.com
  HostName ssh.github.com
  Port 443
  ProxyCommand /usr/bin/nc -X connect -x 192.168.64.1:8888 %h %p
```

(The deny rule on `nc` only applies to commands Claude types; ssh launching it as a proxy command is unaffected.)

#### Step 4: block everything else with Softnet

Change the two `tart run` lines in `agent.sh` so the VM can reach only your Mac's gateway address:

```sh
tart run --no-graphics --net-softnet \
  --net-softnet-block 0.0.0.0/0 --net-softnet-allow 192.168.64.1/32 "$VM"
```

How Softnet combines overlapping block and allow lists isn't documented, so this is the step to verify most carefully (next section). Allowing your Mac's address also allows any *other* service listening on it, so check `lsof -nP -iTCP -sTCP:LISTEN` for services bound to all interfaces, and turn on the macOS firewall's incoming protection for them.

Also consider turning off IPv6 in the image (`networksetup -setv6off Ethernet` in the `agent` build) so nothing slips past over IPv6.

#### Test it

Open a session (`./agent.sh session ~/src/MyApp`), quit Claude to get the shell, and run (you're typing these, so Claude's deny rules don't apply):

```sh
curl -sI https://api.anthropic.com | head -1          # works (any HTTP status)
gh issue list --limit 1                               # works
git ls-remote origin | head -1                        # works
ssh -T git@github.com                                  # reaches GitHub (auth may fail without a key)
curl -sI --max-time 10 https://example.com            # FAILS: refused by the proxy
curl -sI --max-time 10 --noproxy '*' https://example.com   # FAILS: blocked by Softnet
curl -sI --max-time 10 https://1.1.1.1                # FAILS: blocked by Softnet
```

Then check the firewall's monitor and `/opt/homebrew/var/log/tinyproxy/tinyproxy.log` on your Mac: you should see the allowed connections and the refusals. If the `--noproxy` and IP tests succeed, Softnet isn't blocking direct traffic and the setup isn't enforcing anything yet.

#### Limits

- **It filters by name, not content.** Anything sent to an allowed host still gets through. A compromised agent could still send data to, for example, a GitHub repository it can write to (the read-only token prevents that for yours) or to the Anthropic API.
- **Builds that fetch from other hosts fail** (a Swift package hosted outside GitHub, a build script downloading something). That's failing closed; add the host to both the proxy filter and the firewall rules if it's legitimate.
- **Image builds aren't affected.** Packer's build VMs don't use Softnet or the proxy, so Xcode, runtime and Homebrew downloads keep working.
- **The firewall sees only the proxy.** If your checks show Little Snitch can't see VM traffic directly, Softnet is what stops the VM bypassing the proxy, so the Softnet test above is essential.

---

## 14. Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `No route to host` connecting to the VM; Packer stuck at "Waiting for SSH" | Your terminal app lacks Local Network permission ([§3](#grant-your-terminal-local-network-access)). Also check VPNs (`route get <vm-ip>` should show a `bridge…` interface, not `utun…`) and stop Apple's `container` service. |
| Packer times out waiting for SSH, VM is on the desktop | Raise `ssh_timeout` in both `source` blocks (e.g. `"600s"`). If SSH is refused, check *System Settings → General → Sharing → Remote Login* in the VM. |
| `PKR_VAR_admin_password: export PKR_VAR_admin_password first` | Set it in this Terminal window ([§6.2](#62-set-the-vm-admin-password)). |
| `Not found: /Volumes/My Shared Files/xcode/…` | The `.xip` path is wrong or the file moved. Pass the path to the `.xip` as it is on your Mac. |
| `stat agent-base.pkr.hcl: no such file or directory` | Run `agent.sh` from the folder with both files, or keep them together. |
| Build fails at `tart rename` | Your Tart version may not have `rename`. Run `tart --help`; as a workaround, change the `tart rename` line in `swap()` in `agent.sh` to `tart clone "$1-next" "$1" && tart delete "$1-next"`. |
| Build fails at `sysadminctl -autologin` | Syntax may differ on your macOS version; check `sysadminctl -h` in a VM. |
| `<platform> <version> is not available for download` | The retry with `-architectureVariant arm64` failed too. This Xcode may not offer that runtime from the command line; see *Older runtimes* in [§6.4](#64-choose-sdk-platforms-and-versions). |
| `xcrun simctl runtime delete all` fails | Check `xcrun simctl runtime delete --help`; delete runtimes by identifier instead (`xcrun simctl runtime list`). |
| A job's log shows nearly every command denied | Auto mode wasn't available, so the session started in Manual mode, which denies everything that would prompt in `-p` runs. Check the Claude Code version and auto mode requirements in the [permission modes docs](https://code.claude.com/docs/en/permission-modes). |
| Softnet errors when starting a run | Softnet needs SUID or passwordless sudo ([§3](#softnet-network-isolation-for-runs)); or remove `--net-softnet` to test. |
| Can't start a VM: limit reached | Only two macOS VMs can run at once. `tart list` shows running ones; `tart stop <name>`. |
| macOS setup screens in the `--gui` window | First login of the `agent` account in each fresh clone. Harmless for Claude. Getting past them once in the image needs an extra build step. |
| `BLOCKED: the agent's commits change files that define its own limits` | Intended: see [§11](#11-review-and-integrate-the-results). The work is on `agent-quarantine/<run>`. |
| `Could not build the audit report.` | Check that `jq` is installed (`jq --version`). The raw data is still in `audit.jsonl` and `events.stream.jsonl`. |
| A report shows calls as **blocked** that weren't denied | A blocked call is one with no recorded result. The last call of a run that was stopped, or a tool whose result hook didn't fire, also shows this way. |
| A run was killed and its VM is left over | `tart list`, then `tart stop job-…; tart delete job-…`. If `~/agent-jobs/<run>/out.bundle` exists, fetch it: `git fetch ~/agent-jobs/<run>/out.bundle agent/<run>:agent/<run>`. |
| `Remote host identification has changed` warnings | Shouldn't happen: the scripts don't record VM host keys, since each VM is new. For manual `ssh`, add `-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null`. |
| Software Update in a VM stalls | Expected; see [Update macOS](#update-macos). Stop the VM and delete it. |

### Logging in to a VM yourself

```sh
tart list                                   # find the VM name
ssh admin@"$(tart ip <name>)"               # as admin, with your admin password
ssh agent@"$(tart ip <name>)"               # as agent, with your SSH key
```

---

## 15. Not yet verified

These parts were written from documentation or memory and haven't been confirmed end-to-end; check them on your first runs:

- `tart rename` (used to swap in new images) and `sysadminctl -autologin set`.
- `xcrun simctl runtime delete all`.
- Softnet setup and SSH from the host into a VM running on Softnet.
- Auto mode's availability and behaviour in `claude -p` with your Claude Code version.
- Whether the release (not beta) Xcode 27.2 bundles `xcprojformatter`.
- Whether macOS setup screens appear in `--gui` sessions.
- How the iOS Simulator performs inside a Tart guest.
- The audit hook payloads: the field `PermissionDenied` uses for its reason, whether `Bash` results include an exit code, and the format of session transcripts. The report falls back gracefully if a field is missing.
- For the optional network allowlist: whether Little Snitch/LuLu can see Tart VM traffic directly, how Softnet combines `--net-softnet-block 0.0.0.0/0` with an allow entry, and the exact tinyproxy directive names in your version.

---

## Appendix A: CLAUDE.md section

The same text as `CLAUDE-tart-vm-section.md`. Paste it into your project's `CLAUDE.md`.

````markdown
## Running in a disposable VM

**Check this first.** Run `echo "$TART_AGENT_VM $AGENT_ATTENDED"` at the start of every session.

- `1 0`: you are an **unattended job** in a throwaway macOS VM (`agent.sh run`). Nobody can answer questions; every rule in this section applies.
- `1 1`: you are in an **attended session** in a throwaway macOS VM (`agent.sh session`). A developer is at the keyboard: ask when something is unclear, and they decide when the session ends. Every other rule in this section still applies.
- Blank: you are on the developer's own Mac. Ignore this section and work as usual.

In the VM, these environment variables are also set:

- `AGENT_BRANCH`: the branch you are working on (already checked out).
- `AGENT_BASE_BRANCH`: the branch you started from.

### Only commits survive

The VM is deleted when you finish. The only thing kept is the commits on `$AGENT_BRANCH` that are not on `$AGENT_BASE_BRANCH`. Uncommitted changes, untracked files, other branches, stashes and anything outside the repo are lost.

- Commit early and often: after each self-contained step that builds, and at least every time you would otherwise stop to report progress.
- Write clear commit messages: a short summary line, then what changed and why. Record any assumptions you made in the message; in unattended jobs nobody can answer questions.
- Stay on `$AGENT_BRANCH`. Don't create, switch to, rename or delete branches, don't change remotes or global git config, and don't use `git stash` as storage.
- Don't rewrite history below `$AGENT_BASE_BRANCH` (no rebasing onto other branches, no amending or squashing commits you didn't make in this job). Amending your own unpublished commits is fine.
- If you can't finish, commit what you have with a message starting `WIP:` that says what's done, what isn't, and what you'd try next.
- Before finishing, run `git status` and make sure the working tree is clean.

### Never push

You have read-only GitHub access. Don't run `git push`, don't change remotes or push URLs, don't disable the pre-push hook, and don't try to open pull requests, issues or comments. A blocked push is expected, not an error to work around. The developer reviews your commits and decides what to publish.

You may read this repository's issues and pull requests with `gh issue list`, `gh issue view`, `gh pr list`, `gh pr view` and `gh pr diff`. Don't use `gh api`, `gh auth`, `gh browse`, `gh repo` or any `gh` command that creates, edits, comments on, merges or checks out anything.

### Don't clone repositories

Work only in the checkout you started in. Don't clone other git repositories: no `git clone`, `gh repo clone`, `git submodule add`, or downloading a repo as an archive, including to read code for reference. Resolving the project's own declared dependencies through the build tools (for example `xcodebuild -resolvePackageDependencies` for Swift packages already listed in the project) is fine. If the task seems to need code from another repository, don't fetch it; say so in your final summary and in a `WIP:` commit if you can't continue without it.

### No web or SSH access

Don't browse or download from the web: no web search or fetch tools, and no `curl`, `wget` or similar HTTP clients, including in scripts you write and run. Don't open URLs (`open https://…`), and don't use `osascript`, `nc`, `socat`, `telnet` or `ftp`. Don't use `ssh`, `scp`, `sftp` or `rsync` to reach other machines. Work from the repository, the installed tools and Xcode's documentation. Fetching the project's declared dependencies through the build tools and using `gh` or `git fetch` against this repository's GitHub remote are the only network access you need. If the task requires information you can't get this way, say so in your final summary.

### Don't change your own limits

Never create, edit, move or delete the files that define how you work, by any means (editing tools, shell commands, scripts or generated files). This includes, but isn't limited to: `CLAUDE.md`, `CLAUDE.local.md` and `AGENTS.md` anywhere in the repo, other agents' instruction files (`GEMINI.md`, `.cursorrules`, `.cursor/`, `.github/copilot-instructions.md`), anything under `.claude/` (settings, agents, commands, hooks, skills), `.mcp.json`, and in your home directory `~/.claude/`, `~/.claude.json`, `~/.job-env`, `~/.agent-audit/`, git configuration and hooks, and shell startup files. Every tool call you make, including denied and failed ones, is logged for the developer's review. If you think one of them should change, describe the change in your final summary and let the developer make it. Commits that touch these files are quarantined and not delivered.

### Blocked actions

You're running in auto mode: a safety classifier reviews actions and may block some. A blocked action is a signal, not an obstacle to route around. Don't retry it in another form; choose a different approach that stays within these rules. In an attended session, tell the developer what was blocked and why you needed it. In an unattended job, if you can't finish without it, describe it in your final summary.

### Building and testing

- Build and test with `xcodebuild`, always with `CODE_SIGNING_ALLOWED=NO`. There are no signing identities in the VM.
- Don't sign, notarize, archive for distribution or upload anything: no `codesign`, `notarytool`, `altool`, `-exportArchive`, `-allowProvisioningUpdates` or `fastlane`.
- Use an iOS Simulator destination. List what exists with `xcrun simctl list devices available`.
- Don't commit a change that doesn't build. If tests fail and you can't fix them, say so in the commit message.
- Pipe long `xcodebuild` output through `xcbeautify` to keep it readable.

### Swift and Xcode tooling only

Use Swift and Xcode's tools (`swift`, `swiftc`, `xcodebuild`, `xcrun`, `simctl`) plus ordinary command-line utilities (`git`, `grep`, `find`, `sed`, `awk`, `jq` and the like). Don't run other languages or interpreters (`python`/`python3`, `node`, `ruby`, `perl`, `php`, `java`, `osascript` and so on), don't start nested shells (`bash -c`, `sh`, `zsh`, `env …`, `eval`, `source`), and don't write and run shell scripts. If you need helper logic, write it in Swift. The project's own build phases run by `xcodebuild` are fine.

### Project file

- After editing `*.xcodeproj/project.xcproj`, run `xcprojformatter --update <path to the .xcodeproj>` if it's available, and confirm the project still builds.
- Don't add or change Run Script build phases, build rules, scheme pre/post actions, package dependencies in `Package.swift`, or signing settings unless the task explicitly asks for it. If the task needs one of these, make it a separate commit and explain it in the message, because the developer reviews these before building on their own Mac.

### Secrets and scope

- `~/.job-env` holds API credentials. Never print, copy, log or commit its contents, and never write tokens into files in the repo.
- Only work inside the repo checkout. Don't install system-wide software or change macOS settings, and don't use `sudo`.
- Don't change your own setup: don't start other `claude` sessions, add MCP servers, or edit Claude Code's settings.
- Use the toolchains and tools already installed. Don't use Homebrew, and don't install or switch language, toolchain or Xcode versions (asdf, mise, nvm, fnm, volta, pyenv, rbenv, rvm, jenv, SDKMAN, rustup, swiftly, swiftenv, xcodes, `xcode-select -s` and the like). Don't install packages or tools globally either: no `gem install`, `pip install`, `pipx`, `uv tool`, `npm`/`yarn`/`pnpm`/`bun` global installs, `npx`/`bunx`, `cargo install`, `go install`, Mint, MacPorts, `mas`, `installer` or `softwareupdate`. This project uses SwiftPM only: resolving its declared Swift package dependencies is fine; CocoaPods, Bundler, npm and other package managers are not used here. If the task needs a tool or version that isn't installed, say so in your summary instead of installing it.

### Finishing

End with a short summary: what you did, the commits you made, what you verified (builds, tests), anything left undone, and assumptions the developer should check. In unattended jobs this summary is saved to the job log. In attended sessions, give it when the developer says they're wrapping up.
````
