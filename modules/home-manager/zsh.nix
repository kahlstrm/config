{ nixosConfigLocation }:
{
  config,
  lib,
  isDarwin,
  isLinux,
  guiEnabled,
  flakeRoot,
  pkgs,
  ...
}:
let

  zsh-custom = import (flakeRoot + /pkgs/zsh-custom) { inherit pkgs; };
in
{
  programs.zsh = {
    enable = true;
    dotDir = "${config.xdg.configHome}/zsh";
    enableCompletion = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;

    sessionVariables = {
      LANG = "en_US.UTF-8";
      LC_CTYPE = "en_US.UTF-8";
      LC_ALL = "en_US.UTF-8";
      PAGER = "less -FiRSwX";
      MANPAGER = "sh -c 'col -bx | bat -l man -p'";
      MANROFFOPT = "-c";
    };

    shellAliases = {
      ghb = "gh browse";
      ghco = "gh pr checkout";
      ghprv = "gh pr view --web";
      copilot = "gh copilot";
      ls = "ls --color=auto";
      rg = "rg --hidden --glob '!.git'";
      cat = "bat --style plain --paging=never";
      dcup = "docker compose up";
      dcdown = "docker compose down";
      # used by git-extended oh-my-zsh plugin
      dotfiles = "git --git-dir ${nixosConfigLocation}/.git --work-tree ${nixosConfigLocation}";
      aliasrg = "alias | rg";
      pollama = "OLLAMA_HOST=https://ollama.p.kalski.xyz ollama";
      nix-ld-enable = "export LD_LIBRARY_PATH=$NIX_LD_LIBRARY_PATH";
      claudec = "claude --continue";
      clauder = "claude --resume";
      claudew = "claude --worktree";
      gemini = "gemini --model pro";
      geminic = "gemini resume latest";
      geminir = "gemini resume";
      oc = "opencode";
    }
    // lib.optionalAttrs (isLinux && guiEnabled) {
      pbcopy = "wl-copy";
      pbpaste = "wl-paste";
    };
    oh-my-zsh = {
      enable = true;
      plugins = [
        "git"
        "terraform"
        "docker"
        "kubectl"
      ]
      ++ zsh-custom.plugins;
      theme = zsh-custom.theme;
      # https://github.com/ohmyzsh/ohmyzsh/wiki/Customization
      custom = "${zsh-custom.out}";
    };
    # TODO: move more stuff from .zshrc/.zprofile here
  };

  programs.zsh.initContent = lib.mkMerge [
    (lib.mkBefore ''
      if [[ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]]; then
        . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
      fi
    '')
    (lib.optionalString isDarwin ''
      eval "$(mise activate --shims zsh)"
    '')
    (
      if isDarwin then
        ''
          listport() {
             if [ ! -z "$1" ]; then
                 lsof -nP -iTCP:$1 -sTCP:LISTEN
                 return
             fi
             lsof -nP -iTCP -sTCP:LISTEN
          }
        ''
      else
        ''
          listport() {
             if [ ! -z "$1" ]; then
                 ss -tnlp | grep ":$1 "
                 return
             fi
             ss -tnlp
          }
        ''
    )
    ''
      ssm-ec2() {
        local instances id global_args=() ssm_args=()

        while [[ $# -gt 0 ]]; do
          case "$1" in
            --profile)
              [[ -z "''${2:-}" ]] && echo "Error: --profile requires a value." >&2 && return 1
              global_args+=(--profile "$2"); shift 2 ;;
            --region)
              [[ -z "''${2:-}" ]] && echo "Error: --region requires a value." >&2 && return 1
              global_args+=(--region "$2"); shift 2 ;;
            *) ssm_args+=("$1"); shift ;;
          esac
        done

        if ! instances=$(aws ec2 describe-instances \
          "''${global_args[@]}" \
          --query "Reservations[].Instances[?State.Name=='running'].[InstanceId, Tags[?Key=='Name'].Value|[0]]" \
          --output text); then
          echo "Failed to list EC2 instances (check AWS profile/credentials)." >&2
          return 1
        fi

        [ -z "$instances" ] && echo "No running instances found." >&2 && return 1

        id=$(printf '%s\n' "$instances" | fzf | awk '{print $1}')
        [ -z "$id" ] && echo "No instance selected." >&2 && return 1

        aws ssm start-session "''${global_args[@]}" --target "$id" "''${ssm_args[@]}"
      }
    ''
    ''
      PATH=$PATH:$HOME/.local/bin:$HOME/.npm/bin
      if command -v go >/dev/null 2>&1; then
        PATH=$PATH:$(go env GOPATH)/bin
      fi
      # Fallback AWS completion (works because aws_completer is bash style and we have _bash_complete available already)
      if command -v aws_completer >/dev/null 2>&1; then
        complete -C aws_completer aws
      fi
      ghrl(){
        if [ -z "$1" ]; then
          echo 'Please provide github username'
          return
        fi
        if [ -z "$2" ] ; then
          gh repo list $1 -L 9999 --json name -q '.[].name'
          return
        fi
        gh repo list $1 -L 9999 --json name -q '.[].name' | grep $2
      }
      if [ -f ~/.zshrc_external ]; then
        source ~/.zshrc_external
      fi
    ''
  ];
}
