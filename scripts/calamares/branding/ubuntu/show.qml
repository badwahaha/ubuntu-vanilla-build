/* Ubuntu vanilla live ISO — Calamares install slideshow (slideshow API 1).
 * Paths are relative to this file under /etc/calamares/branding/ubuntu/
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
            text: qsTr( "Your Ubuntu system is being installed. This can take a few minutes - the slides below highlight what you are getting." )
        }
    }

    Slide
    {
        centeredText: qsTr( "This build is unofficial and has vanilla desktop experience. More lighter than the original which comes with Snap." )
    }

    Slide
    {
        centeredText: qsTr( "Vanilla desktop: a full-featured, stock desktop experience without a flavor's extra packages or layout changes." )
    }

    Slide
    {
        centeredText: qsTr( "No Snap: snapd is not installed. Use APT, Flatpak, and your preferred formats instead of Snap, unless you add it yourself later." )
    }

    Slide
    {
        centeredText: qsTr( "Flatpak, Brave, and more useful extras are set up on the live session; they will be on your new system as configured by this build." )
    }

    Slide
    {
        centeredText: qsTr( "Hardware enablement: the selected HWE kernel is installed with its recommended firmware and microcode, so recent CPUs and devices are supported out of the box." )
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
        centeredText: qsTr( "A curated locale list keeps the welcome and language step quick; the language pack and hunspell dictionary for your chosen locale are added to the new system automatically." )
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
