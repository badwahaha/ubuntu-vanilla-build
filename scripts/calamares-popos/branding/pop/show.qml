/* Pop!_OS live ISO — Calamares install slideshow (slideshow API 1).
 * Paths are relative to this file under /etc/calamares/branding/pop/
 */

import QtQuick 2.0;
import calamares.slideshow 1.0;

Presentation
{
    id: presentation

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
            source: "slide.jpg"
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
            text: qsTr( "Your Pop!_OS system is being installed. This can take a few minutes - the slides below highlight what you are getting." )
        }
    }

    Slide
    {
        centeredText: qsTr( "This is an unofficial Pop!_OS image built from the apt.pop-os.org repositories: snapd is blocked by APT policy, matching Pop!_OS defaults." )
    }

    Slide
    {
        centeredText: qsTr( "The desktop on this ISO matches how it was built—GNOME by default, or XFCE, KDE Plasma, MATE, Cinnamon, Budgie, or LXDE/LXQt as selected, without snapd. COSMIC can be installed afterwards (sudo apt install cosmic-session) on 24.04/26.04 bases." )
    }

    Slide
    {
        centeredText: qsTr( "No Snap: snapd is not installed by default. Use APT, Flatpak, and your preferred formats instead of Snap, unless you add it yourself later." )
    }

    Slide
    {
        centeredText: qsTr( "Flatpak with Flathub is installed. Vendor APT sources for Brave, Librewolf, and Mozilla Firefox are always configured; which of those browsers are preinstalled depends on how this ISO was built. Pacstall is included via the upstream official script when enabled at build time (the default). Browsers present on the live system are kept after installation." )
    }

    Slide
    {
        centeredText: qsTr( "The kernel matches the build choice: the System76 kernel (linux-system76, stable Linux branch, from the Pop!_OS repos) or an Ubuntu HWE kernel (generic / low-latency), with recommended packages." )
    }

    Slide
    {
        centeredText: qsTr( "After copying the system, the installer removes live-session-only packages (Calamares itself, Casper, and other live tooling), so the installed system stays clean." )
    }

    Slide
    {
        centeredText: qsTr( "Full-disk encryption with LUKS2 is offered straight from the partitioning step; pick the encrypted layout and the boot partition stays separate so GRUB can still start." )
    }

    Slide
    {
        centeredText: qsTr( "GParted and standard filesystem tools (ext4, btrfs, xfs, ntfs-3g, FAT) ship in the live session, so disk preparation matches exactly what the installer expects." )
    }

    Slide
    {
        centeredText: qsTr( "A curated locale list keeps the language step responsive; the installer then adds language packs, hunspell data, and LibreOffice localization for your locale when those packages exist." )
    }

    Slide
    {
        centeredText: qsTr( "Hybrid boot: the same image boots on UEFI firmware and on legacy BIOS through GRUB only; no Syslinux or Isolinux is used anywhere in the build." )
    }

    Slide
    {
        centeredText: qsTr( "When installation finishes, you will be prompted to restart. Remove the installation medium so the computer boots from the new disk." )
    }

    function onActivate() {
        presentation.currentSlide = 0;
    }

    function onLeave() {
    }
}
