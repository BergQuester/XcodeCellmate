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
    "Bash(git switch *)", # only the agent branch is collected
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
    "Bash(git config --global *)", # hooksPath, credential helper

    # --- GitHub CLI: reading issues/PRs is allowed; everything else blocked ---
    "Bash(gh api *)", # arbitrary API calls, any repo the token sees
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
    "Bash(gh pr checkout *)", # would switch branches
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
    "Bash(open http*)", # opening URLs in a browser
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
    "Bash(claude *)", # nested sessions, `claude mcp add`, config changes

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
    "Edit(~/.agent-audit/**)", # the audit log of tool calls

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
    "Bash(env *)", # `env python3 …` and similar indirection
    "Bash(eval *)",
    "Bash(exec *)",
    "Bash(source *)",
    "Bash(./*.sh*)", # running shell scripts directly
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

# Fixed so you can unlock the VM's lock screen as agent. SSH as agent stays key-only.
variable "agent_password" {
  type      = string
  default   = "copper-lantern-meadow-27"
  sensitive = true
}

locals {
  # Fails if a simulator runtime registration is Unusable: clones would then lose every runtime
  # shortly after login (see the note at the end of the agent layer). agent.sh runs it too.
  # First removes the one harmless kind: cryptex runtimes (iOS/visionOS 27) are sometimes
  # registered twice at boot, and simdiskimaged marks the original "Cryptex Mount Preferred".
  # Deleting that registration keeps the files, which its Ready twin of the same build uses.
  check_runtimes = <<-EOT
    for _ in $(seq 60); do xcrun simctl runtime list | grep -q '(Copying)' || break; sleep 5; done
    xcrun simctl runtime list | sed -n 's/.*(\([^)]*\)) - \([0-9A-F-]\{36\}\) (Unusable - Cryptex Mount Preferred.*/\1 \2/p' |
      while read -r build id; do
        xcrun simctl runtime list | grep -q "($build) - .* (Ready)" || continue
        echo "Removing duplicate simulator runtime registration $id ($build, Cryptex Mount Preferred)"
        xcrun simctl runtime delete "$id"
      done
    for _ in $(seq 15); do xcrun simctl runtime list | grep -q 'Cryptex Mount Preferred' || break; sleep 2; done
    if xcrun simctl runtime list 2>&1 | grep -i unusable; then echo 'Simulator runtime registrations above are Unusable; clones would lose their simulators. Was the VM rebooted from inside during the build?' >&2; exit 1; fi
    echo 'Simulator runtime registrations OK.'
  EOT

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
    inline_shebang = "/bin/bash -e"
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
    note = "In the VM window: Xcode > Settings > Components > download Documentation (and add any other platforms you want). If macOS asks for the admin password, it's: admin. Then press Enter here."
  }

  # After the documentation download, so only one thing happens in the VM at a time.
  # Skip macOS's first-login setup screens for every user, with Apple's supported mechanism:
  # SkipSetupItems in a com.apple.SetupAssistant.managed profile. macOS installs profiles only
  # with your approval, so open it in the VM and wait until you've approved it. (Plain files in
  # /Library/Managed Preferences don't work: macOS rebuilds that folder at login.)
  provisioner "file" {
    source      = "${path.root}/SkipSetupAssistant.mobileconfig"
    destination = "/tmp/SkipSetupAssistant.mobileconfig"
  }

  provisioner "shell" {
    inline_shebang = "/bin/bash -e"
    inline = [<<-EOT
      id=local.tartvmconfigs.skipsetupassistant
      installed() { sudo profiles list -all 2>/dev/null | grep -q "profileIdentifier: $id$"; }
      if installed; then echo "Setup Assistant profile already installed."; exit 0; fi

      p=/Users/Shared/SkipSetupAssistant.mobileconfig
      sudo cp /tmp/SkipSetupAssistant.mobileconfig "$p" && sudo chmod 644 "$p"
      steps="ACTION NEEDED in the VM window: approve the Setup Assistant profile.
      The VM's admin password is currently: admin
        1. In System Settings > General > Device Management, double-click
           \"Skip Setup Assistant (agent VM images)\" under Downloaded.
        2. Click Install, confirm, and enter the admin password (admin).
      (If System Settings isn't open or the profile isn't listed, double-click
      $p in Finder, then repeat.) The build continues by itself once it's installed."
      # Run in admin's GUI session (this SSH session isn't one): stage the profile, open the
      # Device Management pane, and show the steps in a dialog too.
      gui() { sudo launchctl asuser "$(id -u)" sudo -u "$(id -un)" "$@"; }
      gui open "$p" || true
      sleep 2
      gui open "x-apple.systempreferences:com.apple.Profiles-Settings.extension" || true
      gui osascript -e "display dialog \"$(printf '%s' "$steps" | sed 's/"/\\"/g')\" with title \"Approve profile\" buttons {\"OK\"} default button 1 giving up after 1800" >/dev/null 2>&1 </dev/null &

      echo "=================================================================="
      echo "$steps"
      echo "=================================================================="
      for i in $(seq 360); do
        installed && { echo "Setup Assistant profile installed."; exit 0; }
        [ $((i % 6)) -eq 0 ] && echo "Still waiting for you to approve the profile in the VM window ($((i / 6)) min; steps above)."
        sleep 10
      done
      echo "The Setup Assistant profile wasn't approved within an hour." >&2
      exit 1
    EOT
    ]
  }

  provisioner "shell" {
    inline = [
      "xcodebuild -version",
      "xcrun --sdk iphoneos --show-sdk-version",
      "xcrun simctl list runtimes",
      local.check_runtimes,
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
      "AGENT_PW=${var.agent_password}",
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
      sa DidSeeAppStore -bool true
      # LastSeenGlassTintUpsell is the Liquid Glass look screen. The age range screen
      # (LastSeenAgeRangeSelection) is left unseen on purpose: you answer it at the pause below.
      for k in LastSeenCloudProductVersion LastSeenDiagnosticsProductVersion LastSeenSiriProductVersion \
               LastSeenIntelligenceProductVersion LastPreLoginTasksPerformedVersion \
               LastSeenGlassTintUpsellProductVersion LastSeeniCloudStorageServicesProductVersion \
               LastSeenSyncProductVersion; do
        sa "$k" "$os_ver"
      done
      sa LastSeenBuddyBuildVersion "$os_build"
      sa LastPreLoginTasksPerformedBuild "$os_build"
      sa GestureMovieSeen none
      sa SkipFirstLoginOptimization -bool true
      sa MiniBuddyShouldLaunchToResumeSetup -bool false
      sudo -u agent defaults write com.apple.assistant.support "Assistant Enabled" -bool false   # Siri off

      # The flags above are a fallback. The screens that need SkipSetupItems (Apple Account,
      # Get Started, Welcome to macOS…) are skipped by the profile installed in the Xcode layer.
      sudo profiles list -all 2>/dev/null | grep -q "profileIdentifier: local.tartvmconfigs.skipsetupassistant$" || {
        echo "The Setup Assistant profile isn't installed in xcode-base. Rebuild the Xcode layer (./agent.sh xcode <xip>) and approve it at the pause." >&2
        exit 1
      }

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
      # agent's password is fixed (for the lock screen), so sshd mustn't accept it.
      sudo mkdir -p /etc/ssh/sshd_config.d
      printf '%s\n' 'Match User agent' '  PasswordAuthentication no' '  KbdInteractiveAuthentication no' |
        sudo tee /etc/ssh/sshd_config.d/100-agent-key-only.conf >/dev/null
      sudo sshd -T -C user=agent,host=localhost,addr=127.0.0.1 | grep -qx 'passwordauthentication no' ||
        { echo "sshd still accepts passwords for agent" >&2; exit 1; }

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
  #
  # mcp-server stores these permissions for the user who owns the login session it runs in
  # (not $HOME or SUDO_USER), and signs them with a hash in that user's login keychain, which
  # must be unlocked to write it (not to read it). So it runs in a session of agent's own:
  # SSH to localhost with a throwaway key, a sudo rule for mcp-server only, and agent's login
  # keychain created and unlocked with its password. The key and the sudo rule are removed after.
  provisioner "shell" {
    inline_shebang   = "/bin/bash -e"
    environment_vars = ["AGENT_PW=${var.agent_password}"]
    inline = [<<-EOT
      # Jobs clone the repo into this (empty) folder; Xcode may serve projects only under it.
      sudo -u agent mkdir -p /Users/agent/work

      tmp="$(mktemp -d)"
      ssh-keygen -q -t ed25519 -N '' -f "$tmp/key"
      sudo cp -p /Users/agent/.ssh/authorized_keys "$tmp/authorized_keys"
      # With an EXIT trap, bash 3.2 exits 0 after a syntax error, so Packer would carry on.
      # The last line sets completed=1; any other exit is a failure.
      completed=0
      cleanup() {
        rc=$?
        sudo rm -f /etc/sudoers.d/zz-agent-mcp-server
        sudo cp -p "$tmp/authorized_keys" /Users/agent/.ssh/authorized_keys
        rm -rf "$tmp"
        if [ "$completed" != 1 ] && [ "$rc" = 0 ]; then rc=1; fi
        exit "$rc"
      }
      trap cleanup EXIT
      sudo -u agent tee -a /Users/agent/.ssh/authorized_keys < "$tmp/key.pub" >/dev/null
      echo 'agent ALL=(root) NOPASSWD: /usr/bin/xcrun mcp-server *' | sudo tee /etc/sudoers.d/zz-agent-mcp-server >/dev/null
      sudo chmod 440 /etc/sudoers.d/zz-agent-mcp-server
      sudo visudo -cqf /etc/sudoers.d/zz-agent-mcp-server

      # The password goes over stdin (first line), not the command line.
      { printf '%s\n' "$AGENT_PW"; cat <<'MCP'; } |
      set -e
      trap 'echo "MCP setup in agent session: failed at line $LINENO (exit $?)" >&2' ERR
      echo "MCP setup in agent session: $(id -un), keychain"
      kc=login.keychain
      [ -f ~/Library/Keychains/login.keychain-db ] || security create-keychain -p "$AGENT_PW" "$kc"
      security list-keychains -d user -s "$kc"
      security default-keychain -d user -s "$kc"
      # Fails (silently) in an SSH session; the name login.keychain is what makes it agent's
      # login keychain at sign-in anyway.
      security login-keychain -d user -s "$kc" 2>/dev/null || echo "MCP setup in agent session: (couldn't mark it as the login keychain; continuing)"
      security unlock-keychain -p "$AGENT_PW" "$kc"
      echo "MCP setup in agent session: mcp-server"
      sudo -n /usr/bin/xcrun mcp-server enable --unsafe-always-allow-all-agents
      sudo -n /usr/bin/xcrun mcp-server allow-folder /Users/agent/work --always
      security lock-keychain "$kc"
      # Checked here, in agent's session: run from admin's (e.g. via sudo -u agent), status
      # reports admin's settings, not agent's.
      echo "Xcode MCP status for agent:"
      xcrun mcp-server status | tee /tmp/agent-mcp-status
      grep -q '^Permission: enabled' /tmp/agent-mcp-status
      ls ~/Library/Keychains/login.keychain-db
      ls ~/"Library/Group Containers/group.com.apple.dt.Xcode.SecureSettingsContainer/CodingAssistant/HeadlessPermissions/mcp-server.json"
      rm -f /tmp/agent-mcp-status
      MCP
        ssh -i "$tmp/key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
          agent@localhost 'exec /bin/bash -c "read -r AGENT_PW && export AGENT_PW && exec /bin/bash -s"' ||
        { rc=$?; echo "Enabling Xcode MCP for agent failed with exit $rc (255: the SSH connection itself; see above)" >&2; exit 1; }
      completed=1
    EOT
    ]
  }

  # The age range screen is answered after this build, by agent.sh in a boot from the host
  # (age_range): never reboot inside a build. A reboot from inside the VM makes simdiskimaged
  # re-register every simulator runtime and mark the originals Unusable; each clone then cleans
  # those up at login, force-unmounting the shared volumes, and the simulators vanish.
  provisioner "shell" {
    inline = [local.check_runtimes]
  }

  # Last: retire admin/admin. sysadminctl doesn't change the login keychain's password, so
  # change it too, or admin's keychain stays locked with the old one.
  provisioner "shell" {
    environment_vars = ["NEW_ADMIN_PW=${var.admin_password}"]
    inline = [
      "sudo sysadminctl -resetPasswordFor admin -newPassword \"$NEW_ADMIN_PW\" -adminUser admin -adminPassword admin",
      "security set-keychain-password -o admin -p \"$NEW_ADMIN_PW\" ~/Library/Keychains/login.keychain-db || echo \"Warning: admin's login keychain still has its old password\" >&2",
    ]
  }
}
