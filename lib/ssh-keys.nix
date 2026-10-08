{
  administrators = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPp11x78hP1TOHinNlmZhPpVxBczbxjygYeTZB5pwOq+"
  ];
  builders.pannu = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ2MJIgY9K0pzFIPnk4D7mFGLSwbJ1koDvWrnKvBsNx4 frame-work-pannu-builder"
  ];
  hosts = {
    "pannu-agents" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILjupE0ttR9L7iIY8pT/jUgQUa9AAH6kNjSd9zClKMeX";
    "jet.kalski.xyz" =
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJuFoL+bSI5l0VM9kkl6Fj5g2yMor9osv2rnTNLz3KKR";
    "p.kalski.xyz" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFk8+06RzXtg+i6G8YZBB4YPHB55FyhtpgjELqU5bYMF";
    "poenttoe.kalski.xyz" =
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM3Ej4EpcyblV2ULtqb9sCg8vM1zH96sy/eVjwEzv/l6";
  };
}
