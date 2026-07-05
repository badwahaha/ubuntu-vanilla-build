/* Pop!_OS live ISO — Calamares install slideshow (slideshow API 1).
 * Paths are relative to this file under /etc/calamares/branding/pop/
 *
 * Styled after the Pop!_OS dark theme. The accent colors are sampled from
 * the official Pop!_OS wallpapers (pop-os/wallpapers — the same set that
 * system76.com/merch/desktop-wallpapers distributes):
 *   #333136 charcoal    kate-hazen-unleash-your-robot background / Pop dark
 *   #FAA41A Pop orange  brand accent
 *   #48B9C7 Pop teal    brand accent
 *   #589AC7 ice blue    nick-nazzaro-ice-cave
 *   #87C1DA ice light   nick-nazzaro-ice-cave
 *   #877DAC lavender    nick-nazzaro-space-blue
 *   #96C295 sage        kate-hazen-mort1mer
 *   #DDD793 sand        kate-hazen-mort1mer
 *   #587288 slate       kate-hazen-pop-m3lvin
 */

import QtQuick 2.0;
import calamares.slideshow 1.0;

Presentation
{
    id: presentation

    // Pop!_OS charcoal backdrop behind every slide.
    Rectangle {
        anchors.fill: parent
        z: -1
        color: "#333136"
    }

    function nextSlide() {
        presentation.goToNextSlide();
    }

    Timer {
        id: advanceTimer
        interval: 7500
        running: presentation.activatedInCalamares
        repeat: true
        onTriggered: nextSlide()
    }

    Slide
    {
        Image {
            id: hero
            source: "slide.png"
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: -24
            width: Math.min( presentation.width * 0.88, 720 )
            height: Math.min( presentation.height * 0.5, 400 )
            fillMode: Image.PreserveAspectFit
            smooth: true
        }

        Text {
            anchors {
                top: hero.bottom
                topMargin: 12
                horizontalCenter: parent.horizontalCenter
            }
            width: presentation.width * 0.9
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            color: "#F6F6F6"
            text: qsTr( "Your Pop!_OS system is being installed. This can take a few minutes - the slides below highlight what you are getting." )
        }
    }

    Slide
    {
        Text {
            id: body1
            anchors.centerIn: parent
            width: presentation.width * 0.82
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            color: "#F6F6F6"
            text: qsTr( "This is an unofficial Pop!_OS image built from the apt.pop-os.org repositories: snapd is blocked by APT policy, matching Pop!_OS defaults (except for the bootloader, it uses GRUB instead of systemd-boot)." )
        }
        Rectangle {
            width: 56; height: 4; radius: 2
            color: "#FAA41A"
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: body1.top
            anchors.bottomMargin: 18
        }
    }

    Slide
    {
        Text {
            id: body2
            anchors.centerIn: parent
            width: presentation.width * 0.82
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            color: "#F6F6F6"
            text: qsTr( "The desktop on this ISO matches how it was built—GNOME by default, or XFCE, KDE Plasma, MATE, Cinnamon, Budgie, or LXDE/LXQt as selected, without snapd. COSMIC can be installed afterwards (sudo apt install cosmic-session) on 24.04/26.04 bases." )
        }
        Rectangle {
            width: 56; height: 4; radius: 2
            color: "#48B9C7"
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: body2.top
            anchors.bottomMargin: 18
        }
    }

    Slide
    {
        Text {
            id: body3
            anchors.centerIn: parent
            width: presentation.width * 0.82
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            color: "#F6F6F6"
            text: qsTr( "No Snap: snapd is not installed by default. Use APT, Flatpak, and your preferred formats instead of Snap, unless you add it yourself later." )
        }
        Rectangle {
            width: 56; height: 4; radius: 2
            color: "#589AC7"
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: body3.top
            anchors.bottomMargin: 18
        }
    }

    Slide
    {
        Text {
            id: body4
            anchors.centerIn: parent
            width: presentation.width * 0.82
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            color: "#F6F6F6"
            text: qsTr( "Flatpak with Flathub is installed. Vendor APT sources for Brave, Librewolf, and Mozilla Firefox are always configured; which of those browsers are preinstalled depends on how this ISO was built. Pacstall is included via the upstream official script when enabled at build time (the default). Browsers present on the live system are kept after installation." )
        }
        Rectangle {
            width: 56; height: 4; radius: 2
            color: "#877DAC"
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: body4.top
            anchors.bottomMargin: 18
        }
    }

    Slide
    {
        Text {
            id: body5
            anchors.centerIn: parent
            width: presentation.width * 0.82
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            color: "#F6F6F6"
            text: qsTr( "The kernel matches the build choice: the System76 kernel (linux-system76, stable Linux branch, from the Pop!_OS repos) or an Ubuntu HWE kernel (generic / low-latency), with recommended packages." )
        }
        Rectangle {
            width: 56; height: 4; radius: 2
            color: "#96C295"
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: body5.top
            anchors.bottomMargin: 18
        }
    }

    Slide
    {
        Text {
            id: body6
            anchors.centerIn: parent
            width: presentation.width * 0.82
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            color: "#F6F6F6"
            text: qsTr( "After copying the system, the installer removes live-session-only packages (Calamares itself, Casper, and other live tooling), so the installed system stays clean." )
        }
        Rectangle {
            width: 56; height: 4; radius: 2
            color: "#DDD793"
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: body6.top
            anchors.bottomMargin: 18
        }
    }

    Slide
    {
        Text {
            id: body7
            anchors.centerIn: parent
            width: presentation.width * 0.82
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            color: "#F6F6F6"
            text: qsTr( "Full-disk encryption with LUKS2 is offered straight from the partitioning step; pick the encrypted layout and the boot partition stays separate so GRUB can still start." )
        }
        Rectangle {
            width: 56; height: 4; radius: 2
            color: "#FAA41A"
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: body7.top
            anchors.bottomMargin: 18
        }
    }

    Slide
    {
        Text {
            id: body8
            anchors.centerIn: parent
            width: presentation.width * 0.82
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            color: "#F6F6F6"
            text: qsTr( "GParted and standard filesystem tools (ext4, btrfs, xfs, ntfs-3g, FAT) ship in the live session, so disk preparation matches exactly what the installer expects." )
        }
        Rectangle {
            width: 56; height: 4; radius: 2
            color: "#87C1DA"
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: body8.top
            anchors.bottomMargin: 18
        }
    }

    Slide
    {
        Text {
            id: body9
            anchors.centerIn: parent
            width: presentation.width * 0.82
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            color: "#F6F6F6"
            text: qsTr( "A curated locale list keeps the language step responsive; the installer then adds language packs, hunspell data, and LibreOffice localization for your locale when those packages exist." )
        }
        Rectangle {
            width: 56; height: 4; radius: 2
            color: "#587288"
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: body9.top
            anchors.bottomMargin: 18
        }
    }

    Slide
    {
        Text {
            id: body10
            anchors.centerIn: parent
            width: presentation.width * 0.82
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            color: "#F6F6F6"
            text: qsTr( "Hybrid boot: the same image boots on UEFI firmware and on legacy BIOS through GRUB only; no Syslinux or Isolinux is used anywhere in the build." )
        }
        Rectangle {
            width: 56; height: 4; radius: 2
            color: "#48B9C7"
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: body10.top
            anchors.bottomMargin: 18
        }
    }

    Slide
    {
        Text {
            id: body11
            anchors.centerIn: parent
            width: presentation.width * 0.82
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            color: "#F6F6F6"
            text: qsTr( "When installation finishes, you will be prompted to restart. Remove the installation medium so the computer boots from the new disk." )
        }
        Rectangle {
            width: 56; height: 4; radius: 2
            color: "#FAA41A"
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: body11.top
            anchors.bottomMargin: 18
        }
    }

    function onActivate() {
        presentation.currentSlide = 0;
    }

    function onLeave() {
    }
}
