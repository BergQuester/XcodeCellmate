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

variable "brew_packages" {
  type    = list(string)
  default = ["gh", "jq", "xcbeautify"] # add tools here, then: ./agent.sh tools
}

variable "claude_deny_rules" {
  type = list(string)
  # Hard blocks for Claude Code in job VMs; apply in every permission mode.
  # They match commands as written, so they're a backstop, not the only guard.
  # Edit, then: ./agent.sh tools
  default = [
    "Bash(git push *)",
    "Bash(git -C * push *)",
    "Bash(git clone *)",
    "Bash(git -C * clone *)",
    "Bash(gh repo clone *)",
    "Bash(gh repo fork *)",
    "Bash(git submodule add *)",
    # Web: Claude's own web tools plus common command-line HTTP clients.
    "WebFetch",
    "WebSearch",
    "Bash(curl *)",
    "Bash(wget *)",
    # Outbound SSH (your Mac's SSH *into* the VM is unaffected).
    "Bash(ssh *)",
    "Bash(scp *)",
    "Bash(sftp *)",
    "Bash(rsync *)",
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
    environment_vars = ["XIP=/Volumes/My Shared Files/xcode/${var.xcode_xip_name}"]
    inline = [<<-EOT
      set -o pipefail
      test -f "$XIP" || { echo "Not found: $XIP" >&2; exit 1; }

      rm -rf /tmp/xcode && mkdir /tmp/xcode && cd /tmp/xcode
      echo "Expanding $XIP (slow)..."
      xip --expand "$XIP"
      APP=$(ls -d /tmp/xcode/*.app | head -1)
      NEW="/Applications/$(basename "$XIP" .xip).app"
      sudo rm -rf "$NEW" && sudo mv "$APP" "$NEW" && rm -rf /tmp/xcode

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

      # iOS SDK is inside Xcode; this adds the matching simulator runtime.
      echo "Download iOS SDK"
      xcodebuild -downloadPlatform iOS
    EOT
    ]
  }

  provisioner "breakpoint" {
    note = "In the VM window: Xcode > Settings > Components > download Documentation. Then press Enter here."
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

  provisioner "shell" {
    inline = [
      "eval \"$(/opt/homebrew/bin/brew shellenv)\"",
      "brew install ${join(" ", var.brew_packages)}",
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

      # Log in as agent at boot, so the VM window (agent.sh --gui) shows agent's
      # desktop and the Simulator it launches, and simulator/UI tests have a GUI session.
      sudo sysadminctl -autologin set -userName agent -password "$AGENT_PW"

      # Key-only SSH login from your Mac.
      sudo -u agent mkdir -p /Users/agent/.ssh
      echo "$AGENT_SSH_PUBKEY" | sudo -u agent tee /Users/agent/.ssh/authorized_keys >/dev/null
      sudo chmod 700 /Users/agent/.ssh
      sudo chmod 600 /Users/agent/.ssh/authorized_keys

      # PATH for Homebrew tools and Claude Code (zsh and bash login shells).
      for f in .zprofile .bash_profile; do
        printf '%s\n' 'eval "$(/opt/homebrew/bin/brew shellenv)"' 'export PATH="$HOME/.local/bin:$PATH"' |
          sudo -u agent tee "/Users/agent/$f" >/dev/null
      done

      # Claude Code for the agent user only.
      sudo -u agent -H bash -lc 'curl -fsSL https://claude.ai/install.sh | bash'

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

  # Deny rules as Claude Code managed settings: highest precedence, and owned by
  # root so the non-admin agent user can't edit or override them.
  provisioner "shell" {
    inline_shebang = "/bin/bash -e"
    inline = [<<-EOT
      DIR="/Library/Application Support/ClaudeCode"
      sudo mkdir -p "$DIR"
      printf '%s\n' '${jsonencode({ permissions = { deny = var.claude_deny_rules } })}' |
        sudo tee "$DIR/managed-settings.json" >/dev/null
      sudo chown root:wheel "$DIR/managed-settings.json"
      sudo chmod 644 "$DIR/managed-settings.json"
      echo "Claude Code managed settings:"
      cat "$DIR/managed-settings.json"
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
