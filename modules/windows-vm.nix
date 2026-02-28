{ config, lib, pkgs, ... }:

let
  cfg = config.services.windowsVm;

  vmXml = pkgs.writeText "${cfg.vmName}.xml" ''
    <domain type='kvm'>
      <name>${cfg.vmName}</name>
      <memory unit='MiB'>${toString cfg.memory}</memory>
      <currentMemory unit='MiB'>${toString cfg.memory}</currentMemory>
      ${lib.optionalString cfg.hugepages.enable ''
      <memoryBacking>
        <hugepages/>
      </memoryBacking>
      ''}
      <vcpu placement='static'>${toString cfg.vcpus}</vcpu>
      <cputune>
        <vcpupin vcpu='0' cpuset='8'/>
        <vcpupin vcpu='1' cpuset='9'/>
        <vcpupin vcpu='2' cpuset='10'/>
        <vcpupin vcpu='3' cpuset='11'/>
        <vcpupin vcpu='4' cpuset='12'/>
        <vcpupin vcpu='5' cpuset='13'/>
        <vcpupin vcpu='6' cpuset='14'/>
        <vcpupin vcpu='7' cpuset='15'/>
        <emulatorpin cpuset='0-7,16-23'/>
      </cputune>
      <os>
        <type arch='x86_64' machine='pc-q35-8.2'>hvm</type>
        <loader readonly='yes' secure='yes' type='pflash'>/run/libvirt/nix-ovmf/edk2-x86_64-secure-code.fd</loader>
        <nvram template='/run/libvirt/nix-ovmf/edk2-i386-vars.fd'>/var/lib/libvirt/qemu/nvram/${cfg.vmName}_VARS.fd</nvram>
        <boot dev='hd'/>
        <boot dev='cdrom'/>
      </os>
      <features>
        <acpi/>
        <apic/>
        <smm state='on'/>
        <hyperv mode='custom'>
          <relaxed state='on'/>
          <vapic state='on'/>
          <spinlocks state='on' retries='8191'/>
          <vpindex state='on'/>
          <synic state='on'/>
          <stimer state='on'/>
          <vendor_id state='on' value='AuthenticAMD'/>
        </hyperv>
        <kvm>
          <hidden state='on'/>
        </kvm>
        <ioapic driver='kvm'/>
        <vmport state='off'/>
      </features>
      <cpu mode='host-passthrough' check='none' migratable='on'>
        <topology sockets='1' dies='1' cores='4' threads='2'/>
        <cache mode='passthrough'/>
        <feature policy='disable' name='hypervisor'/>
        <feature policy='require' name='topoext'/>
      </cpu>
      <clock offset='localtime'>
        <timer name='rtc' tickpolicy='catchup'/>
        <timer name='pit' tickpolicy='delay'/>
        <timer name='hpet' present='no'/>
        <timer name='hypervclock' present='yes'/>
      </clock>
      <on_poweroff>destroy</on_poweroff>
      <on_reboot>restart</on_reboot>
      <on_crash>destroy</on_crash>
      <pm>
        <suspend-to-mem enabled='no'/>
        <suspend-to-disk enabled='no'/>
      </pm>
      <devices>
        <emulator>${pkgs.qemu_kvm}/bin/qemu-system-x86_64</emulator>

        <!-- Primary disk -->
        <disk type='file' device='disk'>
          <driver name='qemu' type='raw' cache='none' io='native' discard='unmap'/>
          <source file='${cfg.diskPath}'/>
          <target dev='vda' bus='virtio'/>
        </disk>

        <!-- Windows installation ISO -->
        <disk type='file' device='cdrom'>
          <driver name='qemu' type='raw'/>
          <source file='${cfg.isoPath}'/>
          <target dev='sda' bus='sata'/>
          <readonly/>
        </disk>

        <!-- VirtIO drivers ISO -->
        <disk type='file' device='cdrom'>
          <driver name='qemu' type='raw'/>
          <source file='/var/lib/libvirt/images/virtio-win.iso'/>
          <target dev='sdb' bus='sata'/>
          <readonly/>
        </disk>

        <controller type='usb' model='qemu-xhci' ports='15'/>

        <!-- Input devices for Spice — vioinput driver required in guest -->
        <input type='tablet' bus='usb'/>
        <input type='keyboard' bus='virtio'/>

        <interface type='network'>
          <source network='default'/>
          <model type='virtio'/>
        </interface>

        <!-- SPICE for display and input -->
        <graphics type='spice' port='5901' autoport='no'>
          <listen type='address' address='127.0.0.1'/>
          <image compression='off'/>
        </graphics>
        <!-- QXL for software rendering — works natively with SPICE, no extra drivers needed for install -->
        <video>
          <model type='qxl' ram='65536' vram='65536' vgamem='16384' heads='1'/>
        </video>

        <!-- QEMU guest agent channel -->
        <channel type='unix'>
          <target type='virtio' name='org.qemu.guest_agent.0'/>
        </channel>

        <!-- Virtual TPM 2.0 for Windows 11 -->
        <tpm model='tpm-crb'>
          <backend type='emulator' version='2.0'/>
        </tpm>

        <memballoon model='virtio'/>
        <rng model='virtio'>
          <backend model='random'>/dev/urandom</backend>
        </rng>
      </devices>
    </domain>
  '';
in
{
  options.services.windowsVm = {
    enable = lib.mkEnableOption "Windows 11 VM with software rendering and RDP access";

    user = lib.mkOption {
      type = lib.types.str;
      default = "ngarvey";
      description = "User that belongs to libvirt/kvm groups.";
    };

    vmName = lib.mkOption {
      type = lib.types.str;
      default = "windows";
      description = "Libvirt domain name for the VM.";
    };

    memory = lib.mkOption {
      type = lib.types.int;
      default = 16384;
      description = "VM RAM in MiB.";
    };

    vcpus = lib.mkOption {
      type = lib.types.int;
      default = 8;
      description = "Number of vCPUs (pinned to CCD1, cores 8-15 and threads 24-31).";
    };

    diskPath = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/libvirt/images/windows.img";
      description = "Path to the raw disk image for the VM.";
    };

    diskSize = lib.mkOption {
      type = lib.types.str;
      default = "256G";
      description = "Size passed to qemu-img when creating the disk image.";
    };

    isoPath = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/libvirt/images/windows.iso";
      description = "Path to the Windows installation ISO.";
    };

    hugepages = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Pre-allocate hugepages at boot for VM memory backing.";
      };
      count = lib.mkOption {
        type = lib.types.int;
        default = 16384;
        description = "Number of 2 MiB hugepages to allocate (16384 = 32 GiB).";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.libvirtd = {
      enable = true;
      qemu = {
        package = pkgs.qemu_kvm;
        swtpm.enable = true;
        runAsRoot = false;
      };
      onBoot = "start";
      onShutdown = "shutdown";
    };

    systemd.services.libvirt-guests.environment.SHUTDOWN_TIMEOUT = lib.mkForce "10";

    virtualisation.spiceUSBRedirection.enable = true;

    environment.systemPackages = with pkgs; [
      virt-manager
      freerdp
    ];

    users.users.${cfg.user}.extraGroups = [ "libvirtd" "kvm" ];

    boot.kernel.sysctl = lib.mkIf cfg.hugepages.enable {
      "vm.nr_hugepages" = cfg.hugepages.count;
    };

    # Ensure /var/lib/libvirt/images exists, define the VM, and start the
    # default NAT network if it isn't already running.
    systemd.services.define-windows-vm = {
      description = "Define ${cfg.vmName} libvirt domain";
      after = [ "libvirtd.service" ];
      requires = [ "libvirtd.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        VIRSH="${pkgs.libvirt}/bin/virsh"
        QEMU_IMG="${pkgs.qemu_kvm}/bin/qemu-img"

        # Ensure image directory exists
        mkdir -p /var/lib/libvirt/images

        # Create disk image if absent
        if [ ! -f "${cfg.diskPath}" ]; then
          echo "Creating disk image at ${cfg.diskPath} (${cfg.diskSize})"
          "$QEMU_IMG" create -f raw "${cfg.diskPath}" "${cfg.diskSize}"
        fi

        # Start and autostart the default NAT network
        "$VIRSH" net-start default 2>/dev/null || true
        "$VIRSH" net-autostart default 2>/dev/null || true

        # Always redefine the VM so XML changes on rebuild are applied automatically.
        # Undefine first only if it exists and is not running.
        if "$VIRSH" list --all --name | grep -qx "${cfg.vmName}"; then
          if "$VIRSH" list --state-running --name | grep -qx "${cfg.vmName}"; then
            echo "VM ${cfg.vmName} is running, skipping redefine"
          else
            echo "Redefining VM ${cfg.vmName}"
            "$VIRSH" undefine "${cfg.vmName}" --nvram 2>/dev/null || "$VIRSH" undefine "${cfg.vmName}"
            "$VIRSH" define ${vmXml}
          fi
        else
          echo "Defining VM ${cfg.vmName}"
          "$VIRSH" define ${vmXml}
        fi
      '';
    };
  };
}
