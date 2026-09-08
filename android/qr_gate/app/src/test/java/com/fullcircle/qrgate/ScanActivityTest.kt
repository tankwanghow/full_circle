package com.fullcircle.qrgate

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ScanActivityTest {
    @Test
    fun pickBadgePrefersFcqaWhenTwoCodesPresent() {
        val bare = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        val fcqa = "fcqa:11111111-2222-3333-4444-555555555555"
        assertEquals(
            "11111111-2222-3333-4444-555555555555",
            ScanActivity.pickBadge(listOf(bare, fcqa)),
        )
    }

    @Test
    fun pickBadgeAcceptsBareUuid() {
        val id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        assertEquals(id, ScanActivity.pickBadge(listOf("fcpair:x:y:http://lan", id)))
    }

    @Test
    fun pickBadgeIgnoresPairingAndJunk() {
        assertNull(ScanActivity.pickBadge(listOf("fcpair:id:token:http://x", "hello")))
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
