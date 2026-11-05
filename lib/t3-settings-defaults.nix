# T3 preferences shared by the desktop app and agent environments; see ./t3-settings.nix for how they're applied.
{
  # Agents decide when a thread is done; a linked PR merging or closing shouldn't settle it.
  sidebarAutoSettleOnMerge = false;
  autoResumeLimitedThreads = true;
  branchNamingMode = "semantic";
  linkedEnvironmentsEnabled = true;
}
