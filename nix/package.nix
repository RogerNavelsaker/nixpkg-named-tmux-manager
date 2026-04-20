{ buildGo124Module ? null, buildGo125Module ? null, buildGoModule, fetchFromGitHub, lib }:

let
  manifest = builtins.fromJSON (builtins.readFile ./package-manifest.json);
  sourceRoot = fetchFromGitHub {
    owner = manifest.source.owner;
    repo = manifest.source.repo;
    rev = manifest.source.rev;
    hash = manifest.source.hash;
  };
  licenseMap = {
    "MIT" = lib.licenses.mit;
    "Apache-2.0" = lib.licenses.asl20;
  };
  resolvedLicense =
    if builtins.hasAttr manifest.meta.licenseSpdx licenseMap
    then licenseMap.${manifest.meta.licenseSpdx}
    else lib.licenses.unfree;
  goBuilder =
    if (manifest.nix.goBuilder or "") == "go125" && buildGo125Module != null
    then buildGo125Module
    else if (manifest.nix.goBuilder or "") == "go124" && buildGo124Module != null
    then buildGo124Module
    else buildGoModule;
in
goBuilder {
  pname = manifest.binary.name;
  version = manifest.package.version;
  src = sourceRoot;

  vendorHash =
    if manifest.nix ? vendorHash
    then manifest.nix.vendorHash
    else lib.fakeHash;

  subPackages = [ manifest.binary.package ];
  modRoot = manifest.nix.modRoot or ".";
  proxyVendor = manifest.nix.proxyVendor or false;
  doCheck = false;

  meta = with lib; {
    description = manifest.meta.description;
    homepage = manifest.meta.homepage;
    license = resolvedLicense;
    mainProgram = manifest.binary.name;
    platforms = platforms.linux ++ platforms.darwin;
  };
}
