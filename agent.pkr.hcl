# Two image layers in one file. Use ./agent.sh rather than calling packer directly.
#
#   build "xcode" -> xcode-base : macOS 27 + Xcode + iOS SDK/runtime + docs   (slow, per Xcode)
#   build "agent" -> agent-base : xcode-base + tools + agent user + Claude     (fast, per tool change)
#
# NOTE: inside the <<-EOT script blocks, write shell variables as $VAR, not ${VAR};
# ${...} is HCL interpolation there (escape it as $${VAR} if you need braces).

packer {
  required_plugins {
    tart = {
      version = ">= 1.12.0"
      source  = "github.com/cirruslabs/tart"
    }
  }
}

# ---------- settings you edit ----------

variable "base_image" {
  type    = string
  default = "ghcr.io/cirruslabs/macos-golden-gate-xcode:27" # macOS 27; pin @sha256 for reproducibility
}

variable "sdk_platforms" {
  type = list(string)
  # Simulator runtimes installed with Xcode. Each entry is one of:
  #   "iOS"                 latest runtime of that platform for this Xcode
  #   "watchOS 27.0"        a specific version (or build number, e.g. "iOS 24B5110a")
  #   "iphonesimulator_22A3351.dmg"   a runtime image to import, placed next to the .xip
  # Platforms: iOS, watchOS, tvOS, visionOS. Empty list = latest iOS.
  # Overridden by extra arguments to: ./agent.sh xcode <xip> [platform ...]
  default = []
}

variable "brew_packages" {
  type    = list(string)
  default = ["gh", "jq", "xcbeautify"] # add tools here, then: ./agent.sh tools
}

variable "claude_theme" {
  type = string
  # Preset so attended sessions skip Claude Code's first-run theme picker.
  # auto, dark, light, dark-daltonized, light-daltonized, dark-ansi or light-ansi.
  default = "auto"
}

variable "brew_keep" {
  type = list(string)
  # Packages the base image installed that jobs use. The agent build removes every other
  # formula and cask the base image installed (CI runners, other AI agents, language and
  # version managers, device tools), plus dependencies nothing else needs.
  # brew_packages are always kept.
  default = [
    "tart-guest-agent", # Tart's in-VM helper (tart exec, clipboard)
    "swiftlint",        # projects with a .swiftlint.yml
  ]
}

variable "claude_deny_rules" {
  type = list(string)
  # Hard blocks for Claude Code in job VMs; apply in every permission mode.
  # They match commands as written, so they're a backstop, not the only guard.
  # Edit, then: ./agent.sh tools
  default = [
    # --- Git: no pushing, no other repos, keep the agent branch intact ---
    "Bash(git push *)",
    "Bash(git -C * push *)",
    "Bash(git clone *)",
    "Bash(git -C * clone *)",
    "Bash(git submodule add *)",
    "Bash(git remote add *)",
    "Bash(git remote set-url *)",
    "Bash(git switch *)",              # only the agent branch is collected
    "Bash(git checkout -b *)",
    "Bash(git branch -d *)",
    "Bash(git branch -D *)",
    "Bash(git branch -m *)",
    "Bash(git branch -M *)",
    "Bash(git reset --hard *)",
    "Bash(git clean *)",
    "Bash(git filter-branch *)",
    "Bash(git filter-repo *)",
    "Bash(git update-ref *)",
    "Bash(git config --global *)",     # hooksPath, credential helper

    # --- GitHub CLI: reading issues/PRs is allowed; everything else blocked ---
    "Bash(gh api *)",                  # arbitrary API calls, any repo the token sees
    "Bash(gh auth *)",
    "Bash(gh browse *)",
    "Bash(gh repo *)",
    "Bash(gh pr create *)",
    "Bash(gh pr merge *)",
    "Bash(gh pr comment *)",
    "Bash(gh pr review *)",
    "Bash(gh pr edit *)",
    "Bash(gh pr close *)",
    "Bash(gh pr reopen *)",
    "Bash(gh pr ready *)",
    "Bash(gh pr checkout *)",          # would switch branches
    "Bash(gh issue create *)",
    "Bash(gh issue comment *)",
    "Bash(gh issue edit *)",
    "Bash(gh issue close *)",
    "Bash(gh issue reopen *)",
    "Bash(gh issue delete *)",
    "Bash(gh issue transfer *)",
    "Bash(gh issue develop *)",
    "Bash(gh release *)",
    "Bash(gh gist *)",
    "Bash(gh workflow *)",
    "Bash(gh run *)",
    "Bash(gh secret *)",
    "Bash(gh variable *)",
    "Bash(gh extension *)",
    "Bash(gh codespace *)",
    "Bash(gh ssh-key *)",
    "Bash(gh gpg-key *)",
    "Bash(gh label *)",

    # --- Web and network ---
    "WebFetch",
    "WebSearch",
    "Bash(curl *)",
    "Bash(wget *)",
    "Bash(open http*)",                # opening URLs in a browser
    "Bash(open -a Safari *)",
    "Bash(osascript *)",
    "Bash(nc *)",
    "Bash(ncat *)",
    "Bash(socat *)",
    "Bash(telnet *)",
    "Bash(ftp *)",
    # Outbound SSH (your Mac's SSH *into* the VM is unaffected).
    "Bash(ssh *)",
    "Bash(scp *)",
    "Bash(sftp *)",
    "Bash(rsync *)",

    # --- Claude Code changing its own setup ---
    "Bash(claude *)",                  # nested sessions, `claude mcp add`, config changes

    # --- Files that define the agent's limits (Edit rules cover every file-editing tool) ---
    # In the repo checkout: agent instructions, project settings/agents/hooks, MCP config.
    "Edit(//Users/agent/work/**/CLAUDE.md)",
    "Edit(//Users/agent/work/**/claude.md)",
    "Edit(//Users/agent/work/**/CLAUDE.local.md)",
    "Edit(//Users/agent/work/**/AGENTS.md)",
    "Edit(//Users/agent/work/**/agents.md)",
    "Edit(//Users/agent/work/**/GEMINI.md)",
    "Edit(//Users/agent/work/**/.claude/**)",
    "Edit(//Users/agent/work/**/.mcp.json)",
    "Edit(//Users/agent/work/**/.cursorrules)",
    "Edit(//Users/agent/work/**/.cursor/**)",
    "Edit(//Users/agent/work/**/.github/copilot-instructions.md)",
    "Edit(//Users/agent/work/**/.github/instructions/**)",
    # In the agent's home: Claude Code config, job environment, git policy, shell startup.
    "Edit(~/.claude/**)",
    "Edit(~/.claude.json)",
    "Edit(~/.job-env)",
    "Edit(~/.gitconfig)",
    "Edit(~/.git-hooks/**)",
    "Edit(~/.ssh/**)",
    "Edit(~/.zshenv)",
    "Edit(~/.zprofile)",
    "Edit(~/.zshrc)",
    "Edit(~/.bash_profile)",
    "Edit(~/.bashrc)",
    "Edit(~/.profile)",
    "Edit(//Library/Application Support/ClaudeCode/**)",
    "Edit(~/.agent-audit/**)",         # the audit log of tool calls

    # --- Signing, notarization and distribution ---
    "Bash(codesign *)",
    "Bash(xcrun notarytool *)",
    "Bash(xcrun altool *)",
    "Bash(xcodebuild * -allowProvisioningUpdates*)",
    "Bash(xcodebuild -exportArchive *)",
    "Bash(fastlane *)",

    # --- Non-Xcode languages, interpreters and nested shells ---
    # Swift (swift, swiftc, xcodebuild, xcrun) stays allowed. These rules only cover
    # commands Claude runs; build phases run by xcodebuild are unaffected.
    "Bash(python *)",
    "Bash(python3 *)",
    "Bash(python3.* *)",
    "Bash(/usr/bin/python3 *)",
    "Bash(xcrun python3 *)",
    "Bash(node *)",
    "Bash(deno *)",
    "Bash(ruby *)",
    "Bash(/usr/bin/ruby *)",
    "Bash(irb *)",
    "Bash(perl *)",
    "Bash(/usr/bin/perl *)",
    "Bash(php *)",
    "Bash(lua *)",
    "Bash(tclsh *)",
    "Bash(java *)",
    "Bash(jshell *)",
    "Bash(jsc *)",
    "Bash(Rscript *)",
    "Bash(bash *)",
    "Bash(sh *)",
    "Bash(zsh *)",
    "Bash(dash *)",
    "Bash(ksh *)",
    "Bash(csh *)",
    "Bash(tcsh *)",
    "Bash(fish *)",
    "Bash(/bin/bash *)",
    "Bash(/bin/sh *)",
    "Bash(/bin/zsh *)",
    "Bash(env *)",                     # `env python3 …` and similar indirection
    "Bash(eval *)",
    "Bash(exec *)",
    "Bash(source *)",
    "Bash(./*.sh*)",                   # running shell scripts directly
    # Bare forms, for input piped in (e.g. `cat x | python3`).
    "Bash(python)",
    "Bash(python3)",
    "Bash(node)",
    "Bash(ruby)",
    "Bash(perl)",
    "Bash(bash)",
    "Bash(sh)",
    "Bash(zsh)",

    # --- Privilege ---
    "Bash(sudo *)",
    "Bash(su *)",

    # --- Homebrew ---
    "Bash(brew *)",
    "Bash(/opt/homebrew/bin/brew *)",

    # --- Language, toolchain and Xcode version managers ---
    "Bash(asdf *)",
    "Bash(mise *)",
    "Bash(rtx *)",
    "Bash(nvm *)",
    "Bash(fnm *)",
    "Bash(volta *)",
    "Bash(n *)",
    "Bash(corepack *)",
    "Bash(pyenv *)",
    "Bash(uv python *)",
    "Bash(rbenv *)",
    "Bash(rvm *)",
    "Bash(chruby *)",
    "Bash(ruby-install *)",
    "Bash(jenv *)",
    "Bash(sdk *)",
    "Bash(goenv *)",
    "Bash(gvm *)",
    "Bash(rustup *)",
    "Bash(swiftly *)",
    "Bash(swiftenv *)",
    "Bash(xcodes *)",
    "Bash(xcode-select -s *)",
    "Bash(xcode-select --switch *)",

    # --- Package managers and installers (project uses SwiftPM only) ---
    "Bash(pod *)",
    "Bash(bundle *)",
    "Bash(gem *)",
    "Bash(npm *)",
    "Bash(npx *)",
    "Bash(yarn *)",
    "Bash(pnpm *)",
    "Bash(bun *)",
    "Bash(bunx *)",
    "Bash(pip *)",
    "Bash(pip3 *)",
    "Bash(python -m pip *)",
    "Bash(python3 -m pip *)",
    "Bash(pipx *)",
    "Bash(uv *)",
    "Bash(uvx *)",
    "Bash(conda *)",
    "Bash(cargo install *)",
    "Bash(go install *)",
    "Bash(mint *)",
    "Bash(port *)",
    "Bash(mas *)",
    "Bash(installer *)",
    "Bash(softwareupdate *)",
  ]
}

variable "ssh_pubkey_path" {
  type    = string
  default = "~/.ssh/id_ed25519.pub" # your Mac's key; job VMs accept only this key for user "agent"
}

# ---------- set by agent.sh ----------

variable "suffix" {
  type    = string
  default = ""
}

variable "xcode_xip_dir" {
  type    = string
  default = ""
}

variable "xcode_xip_name" {
  type    = string
  default = ""
}

variable "admin_password" {
  type      = string
  default   = ""
  sensitive = true
}

locals {
  agent_password = uuidv4() # agent logs in by key only; this just needs to be unguessable

  # Audit hook: every tool call, its result, failures and denials are appended to
  # ~/.agent-audit/events.jsonl, which agent.sh captures live on your Mac.
  audit_hook = [{ matcher = "*", hooks = [{ type = "command", command = "/usr/local/libexec/agent-audit" }] }]
  managed_settings = {
    permissions = { deny = var.claude_deny_rules }
    hooks = {
      PreToolUse         = local.audit_hook
      PostToolUse        = local.audit_hook
      PostToolUseFailure = local.audit_hook
      PermissionDenied   = local.audit_hook
    }
  }

  # Xcode's MCP server, as root-owned managed MCP config. This file also takes exclusive
  # control: no other MCP servers load, including a repo's .mcp.json (which `claude -p`
  # would otherwise load without asking).
  managed_mcp = {
    mcpServers = { xcode = { type = "stdio", command = "xcrun", args = ["mcpbridge"] } }
  }
}

# ---------- sources ----------

source "tart-cli" "xcode" {
  vm_base_name   = var.base_image
  vm_name        = "xcode-base${var.suffix}"
  cpu_count      = 8
  memory_gb      = 16
  disk_size_gb   = 200
  ssh_username   = "admin" # Cirrus defaults; replaced in the agent layer
  ssh_password   = "admin"
  ssh_timeout    = "300s"
  run_extra_args = ["--dir=xcode:${var.xcode_xip_dir}:ro"] # share the .xip folder read-only
}

source "tart-cli" "agent" {
  vm_base_name = "xcode-base"
  vm_name      = "agent-base${var.suffix}"
  cpu_count    = 8 # size of every job VM
  memory_gb    = 16
  ssh_username = "admin"
  ssh_password = "admin"
  ssh_timeout  = "300s"
}

# ---------- layer 1: Xcode ----------

build {
  name    = "xcode"
  sources = ["source.tart-cli.xcode"]

  provisioner "shell" {
    inline_shebang   = "/bin/bash -e"
    environment_vars = [
      "XIP=/Volumes/My Shared Files/xcode/${var.xcode_xip_name}",
      "SDK_PLATFORMS=${join(";", var.sdk_platforms)}",
    ]
    inline = [<<-EOT
      set -o pipefail
      test -f "$XIP" || { echo "Not found: $XIP" >&2; exit 1; }

      rm -rf /tmp/xcode && mkdir /tmp/xcode && cd /tmp/xcode
      echo "Expanding $XIP (slow)..."
      xip --expand "$XIP"
      APP=$(ls -d /tmp/xcode/*.app | head -1)
      NEW="/Applications/$(basename "$XIP" .xip).app"
      sudo rm -rf "$NEW" && sudo mv "$APP" "$NEW" && cd / && rm -rf /tmp/xcode

      # Keep exactly one Xcode, reachable at a stable path.
      for x in /Applications/Xcode*.app; do [ "$x" = "$NEW" ] || sudo rm -rf "$x"; done
      sudo ln -sfn "$NEW" /Applications/Xcode.app

      # Command line tools come from the selected Xcode.
      sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
      echo "First launch"
      sudo xcodebuild -license accept
      sudo xcodebuild -runFirstLaunch

      echo "Delete unneeded runtimes"
      xcrun simctl runtime delete all

      # SDKs ship inside Xcode; these add the simulator runtimes you asked for
      # (default: the latest iOS runtime for this Xcode).
      SPECS="$SDK_PLATFORMS"
      [ -n "$SPECS" ] || SPECS="iOS"
      echo "$SPECS" | tr ';' '\n' | while read -r platform version; do
        [ -n "$platform" ] || continue
        case "$platform" in
          *.dmg|*.DMG)
            image="$(echo "$platform $version" | sed 's/ *$//')"
            echo "Importing simulator runtime $image"
            xcodebuild -importPlatform "/Volumes/My Shared Files/xcode/$image" </dev/null || exit 1
            ;;
          *)
            if [ -z "$version" ]; then
              echo "Downloading latest $platform simulator runtime"
              xcodebuild -downloadPlatform "$platform" </dev/null || exit 1
            else
              echo "Downloading $platform $version simulator runtime"
              # Some versions only download with an explicit architecture variant.
              xcodebuild -downloadPlatform "$platform" -buildVersion "$version" </dev/null ||
                xcodebuild -downloadPlatform "$platform" -buildVersion "$version" -architectureVariant arm64 </dev/null || {
                  echo "Could not download $platform $version. Older runtimes may not be downloadable by this Xcode:" >&2
                  echo "add it at the next pause (Xcode > Settings > Components), or import a .dmg instead." >&2
                  exit 1
                }
            fi
            ;;
        esac
      done
    EOT
    ]
  }

  provisioner "breakpoint" {
    note = "In the VM window: Xcode > Settings > Components > download Documentation (and add any other platforms you want). Then press Enter here."
  }

  provisioner "shell" {
    inline = [
      "xcodebuild -version",
      "xcrun --sdk iphoneos --show-sdk-version",
      "xcrun simctl list runtimes",
    ]
  }
}

# ---------- layer 2: tools, agent user, Claude Code ----------

build {
  name    = "agent"
  sources = ["source.tart-cli.agent"]

  provisioner "shell" {
    inline_shebang   = "/bin/bash -e"
    environment_vars = ["NEW_ADMIN_PW=${var.admin_password}"]
    inline           = ["[ -n \"$NEW_ADMIN_PW\" ] || { echo 'admin_password not set' >&2; exit 1; }"]
  }

  # Remove the base image's Homebrew packages that aren't in brew_keep or brew_packages.
  # Runs before anything that updates, upgrades or installs, so Homebrew never spends time
  # on packages that are about to go.
  provisioner "shell" {
    inline_shebang = "/bin/bash -e"
    inline = [<<-EOT
      eval "$(/opt/homebrew/bin/brew shellenv)"
      export HOMEBREW_NO_AUTO_UPDATE=1
      keep=" ${join(" ", concat(var.brew_keep, var.brew_packages))} "
      unwanted() { while read -r p; do case "$keep" in *" $p "*) ;; *) echo "$p" ;; esac; done; }

      casks="$(brew list --cask -1 | unwanted)"
      # Formulae installed on request (not just as dependencies), from Homebrew's install receipts.
      formulae="$(for r in "$(brew --cellar)"/*/*/INSTALL_RECEIPT.json; do
          grep -Eq '"installed_on_request"[[:space:]]*:[[:space:]]*true' "$r" && basename "$(dirname "$(dirname "$r")")"
        done | sort -u | unwanted)"

      echo "Removing casks:" $casks
      [ -z "$casks" ] || brew uninstall --cask --force $casks
      echo "Removing formulae:" $formulae
      [ -z "$formulae" ] || brew uninstall --formula --ignore-dependencies $formulae
      brew autoremove

      # Third-party taps the base image added. brew untap refuses a tap that kept packages
      # still come from (e.g. tart-guest-agent's), so only now-unused taps go.
      for t in $(brew tap); do
        case "$t" in homebrew/*) continue ;; esac
        if brew untap "$t" >/dev/null 2>&1; then echo "Removed tap $t"; else echo "Kept tap $t (installed packages use it)"; fi
      done
      brew cleanup --prune=all -s >/dev/null || true

      # --ignore-dependencies must not have taken anything a kept package needs.
      brew missing || { echo "A kept Homebrew package lost a dependency (see above)" >&2; exit 1; }
    EOT
    ]
  }

  provisioner "shell" {
    environment_vars = ["HOMEBREW_NO_UPDATE_REPORT_NEW=1", "HOMEBREW_NO_ENV_HINTS=1"]
    inline = [
      "eval \"$(/opt/homebrew/bin/brew shellenv)\"",
      "brew install ${join(" ", var.brew_packages)}",
      "echo \"Homebrew packages left:\" $(brew leaves --installed-on-request) $(brew list --cask -1)",
    ]
  }

  provisioner "shell" {
    inline_shebang = "/bin/bash -e"
    environment_vars = [
      "AGENT_PW=${local.agent_password}",
      "AGENT_SSH_PUBKEY=${trimspace(file(pathexpand(var.ssh_pubkey_path)))}",
    ]
    inline = [<<-EOT
      # Standard (non-admin) account.
      sudo sysadminctl -addUser agent -fullName "Claude Agent" -password "$AGENT_PW" -home /Users/agent
      sudo createhomedir -c -u agent >/dev/null

      # Skip macOS's first-login Setup Assistant for agent. Start from admin's answers (the
      # base image already skipped it for admin), then mark every known screen as seen for
      # this macOS version, since a newer version shows the screens it adds again.
      if defaults export com.apple.SetupAssistant - > /tmp/setupassistant.plist 2>/dev/null; then
        sudo -u agent defaults import com.apple.SetupAssistant /tmp/setupassistant.plist
      fi
      rm -f /tmp/setupassistant.plist
      os_ver="$(sw_vers -productVersion)"; os_build="$(sw_vers -buildVersion)"
      sa() { sudo -u agent defaults write com.apple.SetupAssistant "$@"; }
      for k in Accessibility ActivationLock AppearanceSetup ApplePaySetup AvatarSetup CloudSetup \
               iCloudLoginForStorageServices Intelligence LockdownMode Privacy ScreenTime SiriSetup \
               SyncSetup SyncSetup2 TermsOfAddress TouchIDSetup TrueTonePrivacy Wallpaper; do
        sa "DidSee$k" -bool true
      done
      for k in LastSeenCloudProductVersion LastSeenDiagnosticsProductVersion LastSeenSiriProductVersion \
               LastSeenIntelligenceProductVersion LastPreLoginTasksPerformedVersion; do
        sa "$k" "$os_ver"
      done
      sa LastSeenBuddyBuildVersion "$os_build"
      sa LastPreLoginTasksPerformedBuild "$os_build"
      sa GestureMovieSeen none
      sa SkipFirstLoginOptimization -bool true
      sa MiniBuddyShouldLaunchToResumeSetup -bool false
      sudo -u agent defaults write com.apple.assistant.support "Assistant Enabled" -bool false   # Siri off

      # Log in as agent at boot, so the VM window (agent.sh --gui) shows agent's
      # desktop and the Simulator it launches, and simulator/UI tests have a GUI session.
      sudo sysadminctl -autologin set -userName agent -password "$AGENT_PW"
      # sysadminctl can leave the base image's /etc/kcpassword (admin's) in place, and the VM
      # then stops at the login screen. Write agent's ourselves: the password plus a NUL, padded
      # to a multiple of 12 bytes, XORed with Apple's fixed key.
      sudo defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser agent
      perl -e '@k = (125,137,82,35,210,188,221,234,163,185,31); $p = $ARGV[0] . "\0"; $p .= "\0" x ((12 - length($p) % 12) % 12); $i = 0; print join "", map { chr(ord($_) ^ $k[$i++ % 11]) } split //, $p' "$AGENT_PW" |
        sudo tee /etc/kcpassword >/dev/null
      sudo chown root:wheel /etc/kcpassword
      sudo chmod 600 /etc/kcpassword

      # Key-only SSH login from your Mac.
      sudo -u agent mkdir -p /Users/agent/.ssh
      echo "$AGENT_SSH_PUBKEY" | sudo -u agent tee /Users/agent/.ssh/authorized_keys >/dev/null
      sudo chmod 700 /Users/agent/.ssh
      sudo chmod 600 /Users/agent/.ssh/authorized_keys

      # Base images may limit Remote Login to Administrators (the com.apple.access_ssh group
      # exists); sshd then accepts agent's key and drops the connection. Allow agent too.
      # Without the group, every user may SSH in; don't create it, as that would lock out admin.
      if dscl . -read /Groups/com.apple.access_ssh >/dev/null 2>&1; then
        sudo dseditgroup -o edit -a agent -t user com.apple.access_ssh
        dsmemberutil checkmembership -U agent -G com.apple.access_ssh | grep -q 'is a member' ||
          { echo "agent is not allowed to use SSH (com.apple.access_ssh)" >&2; exit 1; }
      fi

      # PATH for Homebrew tools and Claude Code (zsh and bash login shells).
      for f in .zprofile .bash_profile; do
        printf '%s\n' 'eval "$(/opt/homebrew/bin/brew shellenv)"' 'export PATH="$HOME/.local/bin:$PATH"' |
          sudo -u agent tee "/Users/agent/$f" >/dev/null
      done

      # Claude Code for the agent user only.
      sudo -u agent -H bash -lc 'curl -fsSL https://claude.ai/install.sh | bash'

      # Skip Claude Code's first-run screens (theme picker, onboarding, release notes) in sessions,
      # and trust ~/work, the only folder sessions run in (jobs with -p never ask).
      sudo -u agent -H bash -l <<'CLAUDECFG'
      set -e
      v="$(claude --version | cut -d' ' -f1)"
      f=~/.claude.json
      [ -s "$f" ] || echo '{}' > "$f"
      jq --arg v "$v" --arg theme "${var.claude_theme}" \
        '.theme = $theme | .hasCompletedOnboarding = true | .lastOnboardingVersion = $v | .lastReleaseNotesSeen = $v
         | .projects["/Users/agent/work"] += {hasTrustDialogAccepted: true, hasCompletedProjectOnboarding: true}' \
        "$f" > "$f.tmp" && mv "$f.tmp" "$f"
      chmod 600 "$f"
      echo "Claude Code $v: theme $(jq -r .theme "$f"), onboarding skipped"
      CLAUDECFG

      # Git: identity, GitHub auth from $GH_TOKEN (set per job), push backstop.
      sudo -u agent -H bash <<'GIT'
      set -e
      git config --global user.name  "Claude Agent"
      git config --global user.email "claude-agent@localhost"
      git config --global credential.https://github.com.helper '!f() { test "$1" = get && echo username=x-access-token && echo "password=$GH_TOKEN"; }; f'
      mkdir -p ~/.git-hooks
      printf '#!/bin/sh\necho "git push is disabled in this VM" >&2\nexit 1\n' > ~/.git-hooks/pre-push
      chmod +x ~/.git-hooks/pre-push
      git config --global core.hooksPath ~/.git-hooks
      GIT
    EOT
    ]
  }

  # Deny rules and audit hooks as Claude Code managed settings: highest precedence, and
  # owned by root so the non-admin agent user can't edit, remove or override them.
  provisioner "shell" {
    inline_shebang = "/bin/bash -e"
    inline = [<<-EOT
      # Audit hook script (root-owned; runs as agent for every hook event).
      sudo mkdir -p /usr/local/libexec
      sudo tee /usr/local/libexec/agent-audit >/dev/null <<'AUDIT'
      #!/bin/bash
      # Claude Code hook: append the hook's JSON input, with a timestamp, as one line.
      dir="$HOME/.agent-audit"
      mkdir -p "$dir" 2>/dev/null
      input="$(cat | tr -d '\n')"
      [ -n "$input" ] || input='{}'
      printf '{"ts":"%s","event":%s}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$input" >> "$dir/events.jsonl"
      exit 0
      AUDIT
      sudo chown root:wheel /usr/local/libexec/agent-audit
      sudo chmod 755 /usr/local/libexec/agent-audit

      DIR="/Library/Application Support/ClaudeCode"
      sudo mkdir -p "$DIR"
      printf '%s\n' '${jsonencode(local.managed_settings)}' |
        sudo tee "$DIR/managed-settings.json" >/dev/null
      sudo chown root:wheel "$DIR/managed-settings.json"
      sudo chmod 644 "$DIR/managed-settings.json"
      echo "Claude Code managed settings:"
      cat "$DIR/managed-settings.json"

      printf '%s\n' '${jsonencode(local.managed_mcp)}' |
        sudo tee "$DIR/managed-mcp.json" >/dev/null
      sudo chown root:wheel "$DIR/managed-mcp.json"
      sudo chmod 644 "$DIR/managed-mcp.json"
      echo "Claude Code managed MCP servers:"
      cat "$DIR/managed-mcp.json"
    EOT
    ]
  }

  # Xcode MCP in headless mode: agents use Xcode's tools without the Xcode app running and
  # without the approval alert, which nobody is there to click. Granting permissions needs
  # sudo, so the agent can't change them. Every agent is allowed because nothing can
  # pre-approve Claude here (approval needs a pending request from a signed-in Claude) and
  # the only agents in a job VM are the job's own.
  provisioner "shell" {
    inline_shebang = "/bin/bash -e"
    inline = [<<-EOT
      # Jobs clone the repo into this (empty) folder; Xcode may serve projects only under it.
      sudo -u agent mkdir -p /Users/agent/work
      sudo xcrun mcp-server enable --unsafe-always-allow-all-agents
      sudo xcrun mcp-server allow-folder /Users/agent/work --always
      echo "Xcode MCP status, as admin and as agent:"
      xcrun mcp-server status
      sudo -u agent -H xcrun mcp-server status
    EOT
    ]
  }

  # Last: retire admin/admin.
  provisioner "shell" {
    environment_vars = ["NEW_ADMIN_PW=${var.admin_password}"]
    inline = [
      "sudo sysadminctl -resetPasswordFor admin -newPassword \"$NEW_ADMIN_PW\" -adminUser admin -adminPassword admin",
    ]
  }
}
