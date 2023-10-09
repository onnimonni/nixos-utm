{
  description = "Description for the project";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    devenv.url = "github:cachix/devenv";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    nixos-anywhere.url = "github:numtide/nixos-anywhere";
    nixos-anywhere.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs @ {flake-parts, ...}:
    flake-parts.lib.mkFlake {inherit inputs;} {
      imports = [
        inputs.devenv.flakeModule
      ];
      systems = ["x86_64-linux" "aarch64-darwin"];
      perSystem = {
        config,
        self',
        inputs',
        pkgs,
        system,
        ...
      }: {
        # Per-system attributes can be defined here. The self' and inputs'
        # module parameters provide easy access to attributes of the same
        # system.
        # Equivalent to  inputs'.nixpkgs.legacyPackages.hello;
        packages.nixosImg = pkgs.fetchurl {
          url = "https://hydra.nixos.org/build/237110262/download/1/nixos-minimal-23.11pre531102.fdd898f8f79e-aarch64-linux.iso";
          sha256 = "sha256-PF6EfDXHJDQHHHN+fXUKBcRIRszvpQrrWmIyltFHn5c=";
        };
        packages.utm = pkgs.utm.overrideAttrs (oldAttrs: rec {
          version = "4.4.2";
          src = pkgs.fetchurl {
            url = "https://github.com/utmapp/UTM/releases/download/v${version}/UTM.dmg";
            #hash = "sha256-aDIjf4TqhSIgYaJulI5FgXxlNiZ1qcNY+Typ7+S5Hc8=";
            hash = "sha256-QKZNIqJpY5ipl6R5/UHjfh6I5NkyFn5xZLy/CL5453g=";
          };
        });
        packages.nixosCmd = pkgs.writeShellApplication {
          name = "nixosCmd";
          runtimeInputs = [self'.packages.utm];
          text = ''
            TT=$(utmctl attach "$NIXOS_NAME" | sed -n -e 's/PTTY: //p')
            echo "TTY IS: $TT"
            DAT=/tmp/ttyDump.dat.''$''$
            trap 'rm "$DAT"' EXIT

            exec 3<"$TT"                         #REDIRECT SERIAL OUTPUT TO FD 3
            cat <&3 > "$DAT" &          #REDIRECT SERIAL OUTPUT TO FILE
            PID=$!                                #SAVE PID TO KILL CAT
            echo -e "$@" > "$TT";
            sleep 0.3s                          #WAIT FOR RESPONSE
            kill $PID                             #KILL CAT PROCESS
            wait $PID 2>/dev/null || true                 #SUPRESS "Terminated" output
            exec 3<&-
            cat $DAT
          '';
        };
        packages.nixosIP = pkgs.writeShellApplication {
          name = "nixosIP";
          runtimeInputs = [self'.packages.nixosCmd pkgs.gnused];
          text = ''
            MAC=$(sed -ne 's/.*\(..:..:..:..:..:..\).*/\1/p' "$UTM_DATA_DIR/$NIXOS_NAME.utm/config.plist")
            # shellcheck disable=SC2001
            MAC1=$(sed -e 's/0\([[:digit:]]\)/\1/' <<< "$MAC")
            IP=$(arp -a | sed -ne "s/.*(\([0-9.]*\)) at $MAC1.*/\1/p")
            echo "$IP"
            #nixosCmd ip a | sed -ne 's/.*inet \([0-9]*\.[0-9]*\.[0-9]*\.[0-9]*\).*scope global.*/\1/p'
          '';
        };
        packages.nixosSetRootPW = pkgs.writeShellApplication {
          name = "nixosSetRootPW";
          runtimeInputs = [self'.packages.nixosCmd];
          text = ''nixosCmd "echo -e '$NIXOS_PW\n$NIXOS_PW' | sudo passwd" '';
        };
        packages.sshNixos = pkgs.writeShellApplication {
          name = "sshNixos";
          runtimeInputs = [self'.packages.nixosIP pkgs.openssh];
          text = ''
            # shellcheck disable=SC2029
            ssh "root@$(nixosIP)" "$@"
          '';
        };
        packages.nixosCreate = pkgs.writeShellApplication {
          name = "nixosCreate";
          runtimeInputs = [
            pkgs.util-linux.bin
            pkgs.coreutils
            pkgs.gnused
            pkgs.openssh
            pkgs.ps
            self'.packages.nixosCmd
            inputs'.nixos-anywhere.packages.default
          ];
          text = ''
            UTM_DATA_DIR="$HOME/Library/Containers/com.utmapp.UTM/Data/Documents";

            NAME=$NIXOS_NAME
            VM_ID=$(uuidgen)
            DISK_ID=$(uuidgen)
            #MAC_ADDR=$(tr -dc A-F0-9 < /dev/urandom | head -c 10 | sed -r 's/(..)/\1:/g;s/:$//;s/^/02:/')
            MAC_ADDR=$(md5sum <<< "$NAME" | head -c 10 | sed -r 's/(..)/\1:/g;s/:$//;s/^/02:/')


            FOLDER="$UTM_DATA_DIR/$NAME.utm"
            if [ -e "$FOLDER" ]; then
              read -r -e -p "The VM [$NAME] exists: should the folder $FOLDER be deleted (y/N)" -i "n" answer
              case "$answer" in
                y | Y | yes ) rm -rf "$FOLDER" ;;
                *) echo "keep existing VM. abort."; exit ;;
              esac
            fi
            # shellcheck disable=SC2009
            if ps aux | grep '[U]TM'; then
              UTM_PID=$(ps ax -o pid,command | grep '[U]TM'|cut -d' ' -f1)
              read -r -e -p "Running at $UTM_PID. Kill? (y/N)" -i "n" answer
              case "$answer" in
                y | Y | yes ) kill "$UTM_PID" ;;
                *) echo "don't stop UTM. abort."; exit ;;
              esac
            fi
            mkdir -p "$FOLDER/Data"
            set -x
            tar xvzf ${./empty.img.gz}
            mv empty.img "$FOLDER/Data/$DISK_ID.img"
            install -m 600 ${./efi_vars.fd} "$FOLDER/Data/efi_vars.fd"
            sed -e "s/XXX_NAME/$NAME/g;s/XXX_VM_ID/$VM_ID/g;s/XXX_DISK_ID/$DISK_ID/g;s/XXX_MAC_ADDR/$MAC_ADDR/g" ${./config.plist} > "$FOLDER/config.plist"

            utmctl start "$NAME"
            utmctl stop "$NAME"
            sleep 1
            osascript ${./setIso.osa} "$NAME" ${self'.packages.nixosImg}
            sleep 2 # sometimes iso is not recognised.. maybe sleep helps

            utmctl start "$NAME"
            while ! nixosCmd ls | grep nixos ; do
              echo "VM $NAME not yet running"
              sleep 2;
            done
            nixosCmd uname
            echo "VM $NAME is running"

            echo "setting password"
            nixosCmd "echo -e '$NIXOS_PW\n$NIXOS_PW' | sudo passwd"
            nixosCmd "sudo mkdir -p /root/.ssh"
            nixosCmd "echo '${builtins.head inputs.self.nixosConfigurations.utm.config.users.users.root.openssh.authorizedKeys.keys}' | sudo tee -a /root/.ssh/authorized_keys"
            sleep 2

            nixos-anywhere --flake .#utm "root@$(nixosIP)" --build-on-remote

            utmctl stop "$NAME"
            osascript ${./removeIso.osa} "$NAME"
            utmctl start "$NAME"

            while ! ssh-keyscan "$(nixosIP)"; do sleep 2; done
            ssh-keygen -R "$(nixosIP)"
          '';
        };
        devenv.shells.default = {
          env.NIXOS_NAME = "MyNixOS";
          env.NIXOS_PW = "foo";
          enterShell = ''
            export UTM_DATA_DIR="$HOME/Library/Containers/com.utmapp.UTM/Data/Documents";
          '';
          packages = builtins.attrValues {
            inherit (self'.packages) utm sshNixos nixosIP nixosCmd nixosSetRootPW nixosCreate;
            inherit (pkgs) coreutils expect;
          };
        };
      };
      flake = {
        # The usual flake attributes can be defined here, including system-
        # agnostic ones like nixosModule and system-enumerating ones, although
        # those are more easily expressed in perSystem.
        nixosConfigurations.utm = inputs.nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            inputs.disko.nixosModules.disko
            {disko.devices.disk.disk1.device = "/dev/vda";}
            ./configuration.nix
          ];
        };
      };
    };
}
