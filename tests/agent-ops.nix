# Static guarantees of the ops VM: its credentials sit outside the ops user's folders and
# behind Claude Code's deny rules, its allow list holds no file access or infrastructure
# writes, and nothing grants the agent root or GitHub write access.
{ pkgs, inputs }:
let
  inherit (pkgs) lib;
  fixture = pkgs.writeText "ops-credential.age" "";
  base = inputs.self.nixosConfigurations.ops;
  # Enroll every credential so the checks see the deployed shape, not an empty one.
  ops =
    (base.extendModules {
      modules = [
        {
          local.agentOps.secretFiles = lib.mapAttrs (_: _: fixture) base.config.local.agentOps.secretFiles;
        }
      ];
    }).config;
  agents = inputs.self.nixosConfigurations.agents.config;
  environment = ops.local.agentEnvironment;
  inherit (environment) user;
  settings = builtins.fromJSON ops.environment.etc."claude-code/managed-settings.json".text;
  inherit (settings.permissions) allow deny;
  credentialPaths = lib.mapAttrsToList (_: credential: credential.file) environment.credentials;
  userFolders = [
    environment.home
    environment.workspaces
    environment.configCheckout
    "/home/"
    "/tmp/"
    "/var/tmp/"
  ];
  under = folder: path: lib.hasPrefix "${lib.removeSuffix "/" folder}/" path;
  # Directories that both Read and Edit rules deny.
  deniedDirectories = lib.filter (directory: lib.elem "Edit(/${directory}/**)" deny) (
    map (rule: lib.removeSuffix "/**)" (lib.removePrefix "Read(/" rule)) (
      lib.filter (lib.hasPrefix "Read(") deny
    )
  );
  # File access, interpreters and anything that changes or prints infrastructure state.
  forbiddenCommands = [
    "cat"
    "less"
    "more"
    "head"
    "tail"
    "sed"
    "awk"
    "cp"
    "mv"
    "rm"
    "tee"
    "dd"
    "install"
    "ln"
    "chmod"
    "chown"
    "touch"
    "base64"
    "xxd"
    "strings"
    "env"
    "printenv"
    "sudo"
    "bash"
    "sh"
    "python3"
    "node"
    "curl"
    "kubectl"
  ];
  forbiddenWords = [
    "apply"
    "destroy"
    "import"
    "state"
    "taint"
    "untaint"
    "output"
    "show"
    "console"
    "-out"
    "-upgrade"
    "-migrate-state"
    "-reconfigure"
    "reset"
    "upgrade"
    "reboot"
    "shutdown"
    "rollback"
    "edit"
    "patch"
    "get"
    "read"
    "cp"
    "config"
    "kubeconfig"
    "gen"
    "checkout"
    "switch"
  ];
  ruleCommand =
    rule:
    let
      match = builtins.match "Bash\\((.*)\\)" rule;
    in
    if match == null then null else builtins.head match;
  words = command: lib.filter (word: word != "") (lib.splitString " " command);
  allowIssues = lib.concatMap (
    rule:
    let
      command = ruleCommand rule;
    in
    if command == null then
      [ "allow rule ${rule} is not a Bash command" ]
    else
      lib.optional (lib.elem (builtins.head (words command)) forbiddenCommands) "allow rule ${rule} runs a forbidden command"
      ++ lib.optional (lib.any (
        word: lib.any (lib.hasPrefix word) (words command)
      ) forbiddenWords) "allow rule ${rule} uses a forbidden subcommand or flag"
      # Wildcards only on talosctl, whose remaining subcommand arguments are flags.
      ++ lib.optional (
        lib.hasInfix "*" command && builtins.head (words command) != "talosctl"
      ) "allow rule ${rule} widens beyond an exact command"
  ) allow;
  issues =
    allowIssues
    ++ lib.optional (credentialPaths == [ ]) "no credentials are provisioned"
    ++ lib.concatMap (
      path:
      lib.optional (lib.any (
        folder: under folder path
      ) userFolders) "credential ${path} is inside a user or project folder"
      ++ lib.optional (
        !lib.any (directory: under directory path) deniedDirectories
      ) "credential ${path} is not covered by Read and Edit deny rules"
    ) credentialPaths
    ++ lib.concatMap (
      secret:
      lib.optional (
        secret.owner != user || secret.mode != "0400"
      ) "secret ${secret.name} is not private to ${user}"
    ) (lib.attrValues ops.age.secrets)
    ++
      lib.concatMap
        (
          variable:
          lib.optional (
            !(ops.environment.sessionVariables ? ${variable})
            || !(ops.systemd.services.t3code.environment ? ${variable})
          ) "${variable} is missing from the shell or T3 environment"
        )
        [
          "TALOSCONFIG"
          "GOOGLE_APPLICATION_CREDENTIALS"
        ]
    ++ lib.optional (
      settings.allowManagedPermissionRulesOnly != true
    ) "other settings files can add permission rules"
    ++ lib.optional (settings.disableAutoMode != "disable") "auto mode can approve commands"
    ++ lib.optional (
      settings.permissions.disableBypassPermissionsMode != "disable"
    ) "bypass mode is available"
    # Root, or a trusted Nix user, reads the credentials without asking.
    ++ lib.optional (lib.elem "wheel" ops.users.users.${user}.extraGroups) "${user} is in wheel"
    ++ lib.optional (lib.any (
      rule:
      lib.elem user (rule.users or [ ])
      || lib.any (group: lib.elem group ops.users.users.${user}.extraGroups) (rule.groups or [ ])
    ) ops.security.sudo.extraRules) "${user} has a sudo rule"
    ++ lib.optional ops.security.doas.enable "doas is enabled"
    ++ lib.optional (lib.any (
      trusted: trusted == user || trusted == "@wheel" || trusted == "@users"
    ) ops.nix.settings.trusted-users) "${user} is a trusted Nix user"
    ++ lib.optional (
      ops.systemd.services.t3code.serviceConfig.NoNewPrivileges != true
    ) "T3 agents can gain privileges"
    ++ lib.optional ops.local.agentGithub.enable "the GitHub App is enabled"
    ++ lib.optional (ops.age.secrets ? agent-github-app) "the GitHub App key is provisioned"
    ++ lib.optional (lib.any (name: lib.hasPrefix "ops-" name) (
      lib.attrNames agents.age.secrets
    )) "the agents VM receives ops credentials";
in
pkgs.runCommand "agent-ops" { } ''
  ${lib.concatMapStrings (issue: "echo ${lib.escapeShellArg issue} >&2\n") issues}
  ${lib.optionalString (issues != [ ]) "exit 1"}
  touch "$out"
''
