package com.fullcircle.qrgate

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ScanActivityTest {
    @Test
    fun pickBadgeTreatsFcqaAndBareOfTheSamePersonAsOne() {
        val id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        assertEquals(
            ScanActivity.BadgePick.One(id),
            ScanActivity.pickBadge(listOf(id, "fcqa:$id")),
        )
    }

    @Test
    fun pickBadgeAcceptsBareUuidAmongJunk() {
        val id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        assertEquals(
            ScanActivity.BadgePick.One(id),
            ScanActivity.pickBadge(listOf("fcpair:x:y:http://lan", id)),
        )
    }

    @Test
    fun pickBadgeIgnoresPairingAndJunk() {
        assertEquals(
            ScanActivity.BadgePick.None,
            ScanActivity.pickBadge(listOf("fcpair:id:token:http://x", "hello")),
        )
    }

    @Test
    fun pickBadgeRefusesTwoDifferentEmployees() {
        val a = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        val b = "11111111-2222-3333-4444-555555555555"
        assertEquals(
            ScanActivity.BadgePick.Ambiguous,
            ScanActivity.pickBadge(listOf("fcqa:$a", "fcqa:$b")),
        )
        assertEquals(
            ScanActivity.BadgePick.Ambiguous,
            ScanActivity.pickBadge(listOf(a, "fcqa:$b")),
        )
    }

    @Test
    fun pickBadgeTwoCopiesOfTheSameFcqaAreOnePerson() {
        val id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        assertEquals(
            ScanActivity.BadgePick.One(id),
            ScanActivity.pickBadge(listOf("fcqa:$id", "fcqa:$id")),
        )
    }

    // --- badge-vs-face occlusion geometry ---
    // Face box is 100x100 at (100,100)-(200,200) => area 10_000.
    private val face = ScanActivity.Box(100, 100, 200, 200)

    @Test
    fun badgeHeldBelowTheChinCoversNothing() {
        val badge = ScanActivity.Box(100, 220, 200, 300)
        assertEquals(0f, ScanActivity.faceCoveredFraction(face, badge), 0.0001f)
        assertFalse(ScanActivity.badgeOccludesFace(face, badge))
    }

    @Test
    fun badgeBesideTheHeadCoversNothing() {
        val badge = ScanActivity.Box(210, 100, 300, 200)
        assertEquals(0f, ScanActivity.faceCoveredFraction(face, badge), 0.0001f)
        assertFalse(ScanActivity.badgeOccludesFace(face, badge))
    }

    @Test
    fun badgeGrazingTheChinIsTolerated() {
        // 2px of overlap across the full width => 200/10_000 = 2%.
        val badge = ScanActivity.Box(100, 198, 200, 260)
        assertEquals(0.02f, ScanActivity.faceCoveredFraction(face, badge), 0.0001f)
        assertFalse(ScanActivity.badgeOccludesFace(face, badge))
    }

    @Test
    fun badgeCoveringExactlyTheThresholdIsTolerated() {
        // 5px of overlap across the full width => 500/10_000 = 5%, the boundary.
        val badge = ScanActivity.Box(100, 195, 200, 260)
        assertEquals(0.05f, ScanActivity.faceCoveredFraction(face, badge), 0.0001f)
        assertFalse(ScanActivity.badgeOccludesFace(face, badge))
    }

    @Test
    fun badgeOverNoseAndMouthIsRejected() {
        // The reported photo: card over the lower 40% of the face.
        val badge = ScanActivity.Box(100, 160, 200, 260)
        assertEquals(0.4f, ScanActivity.faceCoveredFraction(face, badge), 0.0001f)
        assertTrue(ScanActivity.badgeOccludesFace(face, badge))
    }

    @Test
    fun badgeCoveringTheWholeFaceIsRejected() {
        val badge = ScanActivity.Box(50, 50, 250, 250)
        assertEquals(1f, ScanActivity.faceCoveredFraction(face, badge), 0.0001f)
        assertTrue(ScanActivity.badgeOccludesFace(face, badge))
    }

    @Test
    fun degenerateFaceBoxFailsClosed() {
        val empty = ScanActivity.Box(100, 100, 100, 100)
        val badge = ScanActivity.Box(100, 220, 200, 300)
        assertEquals(0f, ScanActivity.faceCoveredFraction(empty, badge), 0.0001f)
        assertTrue(ScanActivity.badgeOccludesFace(empty, badge))
    }

    @Test
    fun largestFaceIsTheOneTested() {
        val small = ScanActivity.Box(0, 0, 10, 10)
        val big = ScanActivity.Box(100, 100, 200, 200)
        assertEquals(big, ScanActivity.largestFace(listOf(small, big)))
        assertNull(ScanActivity.largestFace(emptyList()))
    }

    // --- full face in frame: a 30% arm's-length face must punch; clipped must not ---

    @Test
    fun aThirtyPercentFaceFullyInsideTheFrameIsAccepted() {
        // 300px of 1000 wide, inset on every side — the reported "30% still punches" case.
        val armLength = ScanActivity.Box(350, 400, 650, 800)
        assertTrue(ScanActivity.faceFullyInFrame(armLength, 1000, 1800))
    }

    @Test
    fun aFaceTouchingTheLeftEdgeIsNotFullyInFrame() {
        val clipped = ScanActivity.Box(0, 400, 300, 800)
        assertFalse(ScanActivity.faceFullyInFrame(clipped, 1000, 1800))
    }

    @Test
    fun aFaceTouchingTheTopEdgeIsNotFullyInFrame() {
        val clipped = ScanActivity.Box(350, 0, 650, 400)
        assertFalse(ScanActivity.faceFullyInFrame(clipped, 1000, 1800))
    }

    @Test
    fun aFaceTouchingTheRightOrBottomEdgeIsNotFullyInFrame() {
        assertFalse(ScanActivity.faceFullyInFrame(ScanActivity.Box(700, 400, 1000, 800), 1000, 1800))
        assertFalse(ScanActivity.faceFullyInFrame(ScanActivity.Box(350, 1400, 650, 1800), 1000, 1800))
    }

    @Test
    fun aDegenerateFaceOrImageIsNotFullyInFrame() {
        assertFalse(ScanActivity.faceFullyInFrame(face, 0, 1800))
        assertFalse(ScanActivity.faceFullyInFrame(ScanActivity.Box(100, 100, 100, 200), 1000, 1800))
    }

    @Test
    fun aFaceSittingOnTheEdgeInsetIsNotFullyInFrame() {
        // Visible-half boxes often sit a few pixels in, not at 0.
        val nearLeft = ScanActivity.Box(10, 400, 310, 800)
        assertFalse(ScanActivity.faceFullyInFrame(nearLeft, 1000, 1800))
    }

    @Test
    fun bothEyesAndNoseAreRequiredForAFullFace() {
        assertTrue(ScanActivity.fullFaceFeatures(true, true, true))
        assertFalse(ScanActivity.fullFaceFeatures(true, false, true))
        assertFalse(ScanActivity.fullFaceFeatures(false, true, true))
        assertFalse(ScanActivity.fullFaceFeatures(true, true, false))
    }

    @Test
    fun aTurnedHeadIsNotAFullFace() {
        assertTrue(ScanActivity.faceIsFrontal(0f))
        assertTrue(ScanActivity.faceIsFrontal(20f))
        assertTrue(ScanActivity.faceIsFrontal(-20f))
        assertFalse(ScanActivity.faceIsFrontal(40f))
        assertFalse(ScanActivity.faceIsFrontal(-40f))
    }

    @Test
    fun uprightSizeSwapsWhenTheBufferIsRotated() {
        assertEquals(Pair(1080, 1920), ScanActivity.uprightImageSize(1920, 1080, 90))
        assertEquals(Pair(1080, 1920), ScanActivity.uprightImageSize(1920, 1080, 270))
        assertEquals(Pair(1080, 1920), ScanActivity.uprightImageSize(1080, 1920, 0))
        assertEquals(Pair(1080, 1920), ScanActivity.uprightImageSize(1080, 1920, 180))
    }

    // --- face crop geometry ---

    @Test
    fun cropPadsTheFaceBoxOnEverySide() {
        // 100x100 face, 30% pad => 30px each side.
        val crop = ScanActivity.faceCropBox(face, 0.3f, 1000, 1000)
        assertEquals(ScanActivity.Box(70, 70, 230, 230), crop)
    }

    @Test
    fun cropClampsAtTheTopLeftCorner() {
        val corner = ScanActivity.Box(10, 10, 110, 110)
        val crop = ScanActivity.faceCropBox(corner, 0.3f, 1000, 1000)
        assertEquals(ScanActivity.Box(0, 0, 140, 140), crop)
    }

    @Test
    fun cropClampsAtTheBottomRightEdge() {
        val edge = ScanActivity.Box(900, 900, 1000, 1000)
        val crop = ScanActivity.faceCropBox(edge, 0.3f, 1000, 1000)
        assertEquals(ScanActivity.Box(870, 870, 1000, 1000), crop)
    }

    @Test
    fun cropOfADegenerateFaceHasNoArea() {
        val empty = ScanActivity.Box(50, 50, 50, 50)
        val crop = ScanActivity.faceCropBox(empty, 0.3f, 1000, 1000)
        assertEquals(crop.left, crop.right)
        assertEquals(crop.top, crop.bottom)
    }

    @Test
    fun cropNeverEscapesASmallImage() {
        val crop = ScanActivity.faceCropBox(face, 0.3f, 150, 150)
        assertEquals(ScanActivity.Box(70, 70, 150, 150), crop)
    }
}
