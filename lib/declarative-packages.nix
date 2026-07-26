{ lib }:

let
  safeId = value:
    builtins.isString value && builtins.match "[A-Za-z0-9][A-Za-z0-9+._-]*" value != null;
  safeRelativePath = value:
    builtins.isString value
    && value != ""
    && builtins.substring 0 1 value != "/"
    && builtins.match ".*(^|/)\\.\\.(/|$).*" value == null
    && builtins.match "[A-Za-z0-9+@%_.,/ -]+" value != null;
  require = condition: message: value:
    if condition then value else throw message;
  attrByName = pkgs: name:
    lib.attrByPath (lib.splitString "." name)
      (throw "Declarative HomeWeave package dependency is unavailable: ${name}") pkgs;
  urlHost = url:
    let match = builtins.match "https://([^/]+)/.*" url;
    in if match == null then null else builtins.elemAt match 0;
  renderRunArg = arg:
    if arg == "{out}" then
      ''"$out"''
    else if lib.hasSuffix "={out}" arg then
      "${lib.escapeShellArg (lib.removeSuffix "{out}" arg)}\"$out\""
    else
      lib.escapeShellArg arg;
in
{
  schemaVersion = 1;

  mkOverlay =
    {
      catalog,
      sourceRoot ? null,
    }:
    let
      checkedCatalog =
        require ((catalog.schemaVersion or null) == 1)
          "Declarative HomeWeave package catalog requires schemaVersion 1"
          catalog;
      definitions = checkedCatalog.packages or { };
      mkPackage = final: prev: id: spec:
        let
          checkedId = require (safeId id) "Unsafe declarative HomeWeave package id: ${id}" id;
          kind = spec.kind or (throw "Declarative package ${id} is missing kind");
          version = spec.version or (throw "Declarative package ${id} is missing version");
          metadata = spec.meta or { };
          license = lib.attrByPath (lib.splitString "." (metadata.license or "licenses.unfree")) lib.licenses.unfree lib;
          artifacts =
            if kind == "archive"
            then spec.artifacts or (throw "Declarative package ${id} is missing artifacts")
            else { };
          hasDefaultArtifact = artifacts ? default;
          commonMeta = lib.filterAttrs (_: value: value != null) {
            description = metadata.description or "Declarative fixed-output HomeWeave package ${id}";
            homepage = metadata.homepage or null;
            inherit license;
            mainProgram = metadata.mainProgram or null;
            platforms =
              if kind != "archive" || hasDefaultArtifact
              then lib.platforms.all
              else builtins.attrNames artifacts;
            sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
          };
          platform = artifacts.${final.stdenv.hostPlatform.system} or (artifacts.default or null);
          checkedPlatform = require (platform != null)
            "Declarative package ${id} does not support ${final.stdenv.hostPlatform.system}"
            platform;
          url = checkedPlatform.url or (throw "Declarative package ${id} is missing its platform URL");
          host = urlHost url;
          officialHosts = spec.officialHosts or [ ];
          checkedUrl = require (host != null && builtins.elem host officialHosts)
            "Declarative package ${id} URL must use HTTPS and a reviewed official host"
            url;
          format = checkedPlatform.format or "archive";
          dynamicLinkerWrapper = require
            (!(checkedPlatform.dynamicLinkerWrapper or false) || final.stdenv.hostPlatform.isLinux)
            "Declarative package ${id} may enable dynamicLinkerWrapper only on Linux artifacts"
            (checkedPlatform.dynamicLinkerWrapper or false);
          runtimeLibraryNames = checkedPlatform.runtimeLibraries or [ ];
          runtimeLibraries = require
            (dynamicLinkerWrapper || runtimeLibraryNames == [ ])
            "Declarative package ${id} declares runtimeLibraries without enabling dynamicLinkerWrapper"
            (map (name: attrByName final name) runtimeLibraryNames);
          dynamicLinker = final.stdenv.cc.bintools.dynamicLinker;
          runtimeLibraryPath = lib.makeLibraryPath runtimeLibraries;
          # Some official broker endpoints return an archive from a URL whose
          # final path component has no suffix. Give explicitly typed sources
          # a deterministic filename so Nix's unpack phase selects the right
          # unpacker instead of rejecting the extensionless store path.
          sourceName =
            if format == "zip" then "${checkedId}-${version}.zip"
            else if format == "gzip" then "${checkedId}-${version}.gz"
            else if format == "dmg" then "${checkedId}-${version}.dmg"
            else null;
          src = prev.fetchurl ({
            url = checkedUrl;
            hash = checkedPlatform.sha256 or (throw "Declarative package ${id} is missing SHA-256");
          } // lib.optionalAttrs (sourceName != null) { name = sourceName; });
          install = checkedPlatform.install or { kind = "copy-tree"; };
          installKind = install.kind or "copy-tree";
          installDestination = require (safeRelativePath (install.destination or "."))
            "Declarative package ${id} has an unsafe install destination"
            (install.destination or ".");
          dynamicLinkerExecutablePaths =
            let
              paths = checkedPlatform.dynamicLinkerExecutables or [ ];
              checkedPaths = map (path:
                require (safeRelativePath path)
                  "Declarative package ${id} has an unsafe dynamic-linker executable path"
                  path
              ) paths;
            in
            require (dynamicLinkerWrapper || paths == [ ])
              "Declarative package ${id} declares dynamicLinkerExecutables without enabling dynamicLinkerWrapper"
              (require (installKind == "copy-tree" || paths == [ ])
                "Declarative package ${id} may declare dynamicLinkerExecutables only for copy-tree installs"
                checkedPaths);
          renderDynamicLinkerWrapper = target: realTarget: ''
            mkdir -p "$out/${builtins.dirOf target}"
            cat > "$out/${target}" <<HOME_WEAVE_DYNAMIC_LINKER
            #!${final.runtimeShell}
            exec ${dynamicLinker} \
              --library-path ${lib.escapeShellArg runtimeLibraryPath} \
              "$out/${realTarget}" "\$@"
            HOME_WEAVE_DYNAMIC_LINKER
            chmod 0555 "$out/${target}"
          '';
          copyTreeDynamicLinkerCommands =
            lib.concatMapStringsSep "\n" (path:
              let
                target =
                  if installDestination == "."
                  then path
                  else "${installDestination}/${path}";
                realTarget = ".home-weave-dynamic/${target}";
              in ''
                if [[ ! -f "$out/${target}" ]]; then
                  echo "Declarative package ${id} is missing dynamic-linker executable ${path}" >&2
                  exit 1
                fi
                mkdir -p "$out/${builtins.dirOf realTarget}"
                mv "$out/${target}" "$out/${realTarget}"
                ${renderDynamicLinkerWrapper target realTarget}
              ''
            ) dynamicLinkerExecutablePaths;
          sourceRootValue = checkedPlatform.sourceRoot or null;
          executableCommands = lib.concatMapStringsSep "\n" (entry:
            let
              source = require (safeRelativePath (entry.source or ""))
                "Declarative package ${id} has an unsafe executable source" entry.source;
              target = require (safeRelativePath (entry.target or ""))
                "Declarative package ${id} has an unsafe executable target" entry.target;
            in
            if dynamicLinkerWrapper then ''
              install -Dm755 ${lib.escapeShellArg source} "$out/libexec/${target}"
              ${renderDynamicLinkerWrapper target "libexec/${target}"}
            ''
            else
              ''install -Dm755 ${lib.escapeShellArg source} "$out/${target}"''
          ) (install.files or [ ]);
          gzipOutput =
            if (install.files or [ ]) == [ ] then id
            else (builtins.head install.files).source;
          rawOutput =
            let files = install.files or [ ];
            in require (installKind == "executables" && builtins.length files == 1)
              "Declarative raw package ${id} requires exactly one executable file"
              (builtins.head files).source;
          runProgram = require (safeRelativePath (install.program or ""))
            "Declarative package ${id} has an unsafe installer program" (install.program or "");
          runArgs = lib.concatStringsSep " " (map renderRunArg (install.args or [ ]));
          appBundle = require
            (safeRelativePath (install.bundle or "") && lib.hasSuffix ".app" install.bundle)
            "Declarative package ${id} requires a safe .app bundle path"
            (install.bundle or "");
          appExecutable = require (safeRelativePath (install.executable or ""))
            "Declarative package ${id} requires a safe app executable path"
            (install.executable or "");
          appCommand = require (safeId (install.command or ""))
            "Declarative package ${id} requires a safe app command name"
            (install.command or "");
          installPhase =
            if installKind == "copy-tree" then ''
              runHook preInstall
              mkdir -p "$out/${installDestination}"
              cp -R . "$out/${installDestination}/"
              ${copyTreeDynamicLinkerCommands}
              runHook postInstall
            ''
            else if installKind == "executables" then ''
              runHook preInstall
              ${executableCommands}
              runHook postInstall
            ''
            else if installKind == "run" then ''
              runHook preInstall
              ${lib.escapeShellArg "./${runProgram}"} ${runArgs}
              runHook postInstall
            ''
            else if installKind == "macos-app" then ''
              runHook preInstall
              mkdir -p "$out/Applications" "$out/bin"
              cp -R ${lib.escapeShellArg appBundle} "$out/Applications/"
              ${lib.optionalString final.stdenv.hostPlatform.isDarwin ''
                /usr/bin/xattr -cr \
                  "$out/Applications/${builtins.baseNameOf appBundle}"
              ''}
              ln -s \
                "$out/Applications/${builtins.baseNameOf appBundle}/${appExecutable}" \
                "$out/bin/${appCommand}"
              runHook postInstall
            ''
            else if installKind == "macos-cli-app" then ''
              runHook preInstall
              mkdir -p "$out/libexec/${appCommand}" "$out/bin"
              cp -R \
                ${lib.escapeShellArg "${appBundle}/Contents"} \
                "$out/libexec/${appCommand}/"
              ${lib.optionalString final.stdenv.hostPlatform.isDarwin ''
                /usr/bin/xattr -cr "$out/libexec/${appCommand}"
              ''}
              ln -s \
                "$out/libexec/${appCommand}/${appExecutable}" \
                "$out/bin/${appCommand}"
              runHook postInstall
            ''
            else
              throw "Declarative package ${id} has unsupported install kind ${installKind}";
          passthru = lib.optionalAttrs (spec ? passthru && spec.passthru ? home) {
            home = "${placeholder "out"}/${spec.passthru.home}";
          };
        in
        if kind == "nixpkgs" then
          let
            package = attrByName prev (spec.attr or id);
            actual = lib.getVersion package;
          in
          require (actual == version)
            "Declarative package ${id}: pinned Nixpkgs has ${actual}; expected ${version}"
            package
        else if kind == "archive" then
          prev.stdenvNoCC.mkDerivation ({
            pname = checkedId;
            inherit version src installPhase passthru;
            nativeBuildInputs = lib.optionals (format == "zip") [ prev.unzip ]
              ++ lib.optionals (format == "gzip") [ prev.gzip ]
              ++ lib.optionals (format == "dmg") [ prev.undmg ];
            buildInputs = runtimeLibraries;
            dontUnpack = format == "raw" || format == "gzip";
            # Declarative archives are already-built, checksum-pinned
            # artifacts. Never invoke an incidental configure script or
            # Makefile found inside an upstream source tree.
            dontConfigure = true;
            dontBuild = true;
            preInstall =
              if format == "gzip" then ''
                mkdir -p source
                gzip -dc "$src" > ${lib.escapeShellArg "source/${gzipOutput}"}
                cd source
              ''
              else if format == "raw" then ''
                mkdir -p ${lib.escapeShellArg "source/${builtins.dirOf rawOutput}"}
                cp "$src" ${lib.escapeShellArg "source/${rawOutput}"}
                cd source
              ''
              else "";
            meta = commonMeta;
          } // lib.optionalAttrs (sourceRootValue != null) { sourceRoot = sourceRootValue; })
        else if kind == "bundle" then
          let
            members = map (name: attrByName final name) (spec.members or [ ]);
            links = lib.concatMapStringsSep "\n" (entry:
              let
                package = attrByName final entry.package;
                source = require (safeRelativePath entry.source) "Bundle ${id} has an unsafe link source" entry.source;
                target = require (safeRelativePath entry.target) "Bundle ${id} has an unsafe link target" entry.target;
              in
              ''mkdir -p "$out/$(dirname ${lib.escapeShellArg target})"
                ln -s ${package}/${source} "$out/${target}"''
            ) (spec.links or [ ]);
            aliases = lib.concatMapStringsSep "\n" (entry:
              let
                package = attrByName final entry.package;
                executable = require (safeRelativePath entry.executable) "Bundle ${id} has an unsafe alias executable" entry.executable;
                name = require (safeId entry.name) "Bundle ${id} has an unsafe alias name" entry.name;
              in
              ''cat > "$out/bin/${name}" <<'HOME_WEAVE_ALIAS'
                #!/bin/sh
                exec ${package}/${executable} "$@"
                HOME_WEAVE_ALIAS
                chmod 0555 "$out/bin/${name}"''
            ) (spec.aliases or [ ]);
            exposedBins = lib.concatMapStringsSep "\n" (entry:
              let
                package = attrByName final entry.package;
                path = require (safeRelativePath entry.path) "Bundle ${id} has an unsafe bin path" entry.path;
              in
              ''for executable in ${package}/${path}/*; do
                  [[ -e "$executable" ]] || continue
                  ln -s "$executable" "$out/bin/$(basename "$executable")"
                done''
            ) (spec.exposeBins or [ ]);
          in
          prev.stdenvNoCC.mkDerivation {
            pname = checkedId;
            inherit version;
            dontUnpack = true;
            installPhase = ''
              runHook preInstall
              mkdir -p "$out/bin" "$out/lib"
              ${lib.concatMapStringsSep "\n" (package: ''
                if [[ -d ${package}/bin ]]; then
                  for executable in ${package}/bin/*; do
                    [[ -e "$executable" ]] || continue
                    ln -s "$executable" "$out/bin/$(basename "$executable")"
                  done
                fi
              '') members}
              ${exposedBins}
              ${links}
              ${aliases}
              runHook postInstall
            '';
            passthru = lib.optionalAttrs (spec ? defaultJavaHome) {
              defaultJavaHome =
                let ref = spec.defaultJavaHome; in
                "${attrByName final ref.package}/${ref.path}";
            };
            meta = commonMeta;
          }
        else if kind == "script" then
          let
            scriptFile = require (sourceRoot != null && safeRelativePath (spec.scriptFile or ""))
              "Declarative script package ${id} requires a safe scriptFile beneath sourceRoot"
              (spec.scriptFile or "");
            executableName = require (safeId (spec.executableName or id))
              "Declarative script package ${id} has an unsafe executable name"
              (spec.executableName or id);
            substitutions = spec.substitutions or { };
            tokens = builtins.attrNames substitutions;
            values = map (token:
              let ref = substitutions.${token};
              in "${attrByName final ref.package}/${ref.path or ""}"
            ) tokens;
            scriptText = builtins.replaceStrings
              (map (token: "@${token}@") tokens)
              values
              (builtins.readFile (sourceRoot + "/${scriptFile}"));
            renderedScript = prev.writeText "${id}-script" scriptText;
            runtimePackages = map (name: attrByName final name) (spec.runtimePackages or [ ]);
          in
          prev.stdenvNoCC.mkDerivation {
            pname = checkedId;
            inherit version;
            dontUnpack = true;
            nativeBuildInputs = [ prev.makeWrapper ];
            installPhase = ''
              runHook preInstall
              install -Dm755 ${renderedScript} "$out/bin/${executableName}"
              wrapProgram "$out/bin/${executableName}" \
                --prefix PATH : ${lib.makeBinPath runtimePackages}
              runHook postInstall
            '';
            meta = commonMeta;
          }
        else
          throw "Declarative package ${id} has unsupported kind ${kind}";
    in
    final: prev: lib.mapAttrs (mkPackage final prev) definitions;
}
