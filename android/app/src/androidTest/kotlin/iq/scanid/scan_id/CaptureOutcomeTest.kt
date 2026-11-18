package iq.scanid.scan_id

import android.app.Activity
import androidx.test.runner.AndroidJUnit4
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class CaptureOutcomeTest {
    @Test
    fun emptyFileIsNeverImported() {
        assertFalse(CaptureOutcome.shouldImport(Activity.RESULT_OK, 0))
        assertFalse(CaptureOutcome.shouldImport(Activity.RESULT_CANCELED, 0))
        assertFalse(CaptureOutcome.shouldImport(Activity.RESULT_OK, 10))
    }

    @Test
    fun canceledWriteFromOemCameraIsImported() {
        assertTrue(CaptureOutcome.shouldImport(Activity.RESULT_CANCELED, 50_000))
    }

    @Test
    fun okJpegIsImported() {
        assertTrue(CaptureOutcome.shouldImport(Activity.RESULT_OK, 32))
        assertTrue(CaptureOutcome.shouldImport(Activity.RESULT_OK, 8_000))
    }

    @Test
    fun canceledTinyLeftoverIsNotImported() {
        assertFalse(CaptureOutcome.shouldImport(Activity.RESULT_CANCELED, 200))
    }
}
