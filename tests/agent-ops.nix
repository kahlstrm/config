# Static guarantees of the ops VM: its credentials sit outside the ops user's folders and
# behind Claude Code's deny rules, its allow list holds no file access or infrastructure
# writes, and nothing grants the agent root. GitHub and GitLab access is the operator's
# account behind the same approval gate; ops has no GitHub App.
{ pkgs, inputs }:
let
  inherit (pkgs) lib;
  ops = inputs.self.nixosConfigurations.ops.config;
  inherit (ops.local.agentOps) stateDirectory runtimeDirectory;
  privateKeys = map (name: "${stateDirectory}/${name}") [
    "talos.key"
    "gcp.key"
  ];
  agents = inputs.self.nixosConfigurations.agents.config;
  pannu = inputs.self.nixosConfigurations.pannu.config;
  overBudget =
    budget:
    lib.any (check: !check.assertion && lib.hasPrefix "Agent VM volumes need" check.message)
      (inputs.self.nixosConfigurations.pannu.extendModules {
        modules = [ { local.agentVMDiskBudgetMiB = lib.mkForce budget; } ];
      }).config.assertions;
  environment = ops.local.agentEnvironment;
  inherit (environment) user;
  opsInstructions = builtins.readFile ../modules/agent-ops/instructions.md;
  instructionsOf = machine: machine.environment.etc."agent-instructions.md".source.text;
  settings = builtins.fromJSON ops.environment.etc."claude-code/managed-settings.json".text;
  inherit (settings.permissions) allow deny;
  credentialPaths =
    lib.mapAttrsToList (_: credential: credential.file) environment.credentials ++ privateKeys;
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
    # Acts as the operator's GitHub account and can print its token.
    "gh"
    # Acts as the operator's GitLab account and can print its token.
    "glab"
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
    ++ lib.optional (
      lib.attrNames environment.credentials != [
        "gcp"
        "github"
        "gitlab"
        "kubernetes"
        "talos"
      ]
    ) "ops does not provision exactly the GCP, GitHub, GitLab, Kubernetes and Talos credentials"
    ++ lib.concatMap (
      path:
      lib.optional (lib.any (
        folder: under folder path
      ) userFolders) "credential ${path} is inside a user or project folder"
      ++ lib.optional (
        !lib.any (directory: under directory path) deniedDirectories
      ) "credential ${path} is not covered by Read and Edit deny rules"
    ) credentialPaths
    # Private keys never leave ops, not even encrypted in the repository.
    ++ lib.optional (ops.age.secrets != { }) "ops decrypts agenix secrets"
    ++ lib.optional (lib.any (lib.hasPrefix "ops") (lib.attrNames (builtins.readDir ../secrets))) "the repository holds ops secrets"
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
          "KUBECONFIG"
        ]
    # T3's server reads gh's token for its own GitHub features, without approval; glab's
    # token stays out of reach the same way.
    ++
      lib.concatMap
        (
          variable:
          lib.optional (
            ops.environment.sessionVariables ? ${variable}
            || ops.environment.variables ? ${variable}
            || ops.systemd.services.t3code.environment ? ${variable}
          ) "${variable} is set for the shell or T3"
        )
        [
          "GH_CONFIG_DIR"
          "GLAB_CONFIG_DIR"
        ]
    ++ lib.optional (
      settings.allowManagedPermissionRulesOnly != true
    ) "other settings files can add permission rules"
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
    # Only Claude Code's managed rules gate reads; T3 enables Codex by default when unconfigured.
    ++ lib.mapAttrsToList (id: _: "T3 provider instance ${id} is enabled") (
      lib.filterAttrs (id: instance: id != "claudeAgent" && (instance.enabled or true) != false) (
        environment.t3Settings.providerInstances or { }
      )
    )
    ++
      lib.concatMap
        (
          id:
          lib.optional (
            !(environment.t3Settings.providerInstances or { } ? ${id})
          ) "T3 provider instance ${id} is left at its default"
        )
        [
          "codex"
          "opencode"
        ]
    ++ lib.optional (
      environment.harnesses != [ "claude" ]
    ) "agent-tools installs harnesses besides Claude Code"
    ++ lib.optional ops.local.agentGithub.enable "the GitHub App is enabled"
    ++ lib.optional (
      agents.systemd.services ? ops-credentials
    ) "the agents VM assembles ops credentials"
    # Agents' volumes alone take 240 GiB, so that budget only fails if ops is counted too.
    ++ lib.optional (
      !overBudget (240 * 1024)
    ) "ops' volumes are not counted against pannu's agent disk budget"
    ++ lib.optional (overBudget pannu.local.agentVMDiskBudgetMiB) "the agent VMs' volumes exceed pannu's agent disk budget"
    # Ops' agent checks a task before running it; agents elsewhere don't get ops' rules.
    ++ lib.optional (
      !lib.hasInfix opsInstructions (instructionsOf ops)
    ) "ops' agent instructions lack modules/agent-ops/instructions.md"
    ++ lib.optional (lib.hasInfix opsInstructions (
      instructionsOf agents
    )) "the agents VM's instructions include ops' instructions";
in
pkgs.runCommand "agent-ops" { } ''
  ${lib.concatMapStrings (issue: "echo ${lib.escapeShellArg issue} >&2\n") issues}
  ${lib.optionalString (issues != [ ]) "exit 1"}
  touch "$out"
''
