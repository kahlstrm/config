# Imports cannot depend on pkgs; modulesPath is supplied before module evaluation.
modulesPath: builtins.pathExists "${modulesPath}/launchd"
