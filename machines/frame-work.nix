{
  pkgs,
  currentSystemUser,
  isStable,
  resolvedModules,
  ...
}:
let
  omarchy = false;
in
{
  imports = [
    resolvedModules.mdatp
    resolvedModules.nixos-hardware.framework-amd-ai-300-series
    # Include the results of the hardware scan.
    ./hardware/frame-work.nix
    ../modules/keyd.nix
    (if omarchy then ../modules/omarchy else ../modules/gnome.nix)
    (import ../modules/virt-manager.nix { spiceUSBRedirectionEnabled = false; })
    # ../modules/binbash.nix
    ../modules/fingerprint.nix
    ../modules/intune.nix
    ../modules/linux-entra-sso
  ];

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.initrd.luks.devices."luks-67130c52-43c6-40c3-a4af-c5d9b803aebd".device =
    "/dev/disk/by-uuid/67130c52-43c6-40c3-a4af-c5d9b803aebd";
  boot.kernelPackages = if isStable then pkgs.linuxPackages else pkgs.linuxPackages_latest;
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  # Set the WiFi regulatory domain.
  boot.extraModprobeConfig = ''
    options cfg80211 ieee80211_regdom=FI
  '';
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Enable networking
  networking.networkmanager.enable = true;

  services.tailscale.enable = true;

  # Select internationalisation properties.
  i18n.defaultLocale = "en_US.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "fi_FI.UTF-8";
    LC_IDENTIFICATION = "fi_FI.UTF-8";
    LC_MEASUREMENT = "fi_FI.UTF-8";
    LC_MONETARY = "fi_FI.UTF-8";
    LC_NAME = "fi_FI.UTF-8";
    LC_NUMERIC = "fi_FI.UTF-8";
    LC_PAPER = "fi_FI.UTF-8";
    LC_TELEPHONE = "fi_FI.UTF-8";
    LC_TIME = "fi_FI.UTF-8";
  };

  # firmware updater
  services.fwupd.enable = true;

  # Enable CUPS to print documents.
  services.printing.enable = true;

  # Enable sound with pipewire.
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # If you want to use JACK applications, uncomment this
    #jack.enable = true;

    # use the example session manager (no others are packaged yet so this is enabled by default,
    # no need to redefine it in your config for now)
    #media-session.enable = true;
  };
  hardware.graphics.enable = true;

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.${currentSystemUser} = {
    isNormalUser = true;
    description = "Kalle Ahlstrom";
    extraGroups = [
      "networkmanager"
      "wheel"
    ];
    packages = with pkgs; [
      telegram-desktop
      signal-desktop
      discord
      google-chrome
      mongodb-tools
      mongosh
      btop-rocm
      #  thunderbird
    ];
  };
  services.mdatp.enable = true;

  environment.systemPackages = with pkgs; [
    # microsoft-edge
    rocmPackages.rocm-smi
    winbox4
    azure-cli
  ];
  services.netbird.enable = true;

  # Install firefox.
  programs.firefox.enable = true;

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  # services.openssh.enable = true;

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "24.11"; # Did you read the comment?

}
