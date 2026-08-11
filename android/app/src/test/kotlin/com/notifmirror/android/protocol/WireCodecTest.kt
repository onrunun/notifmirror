package com.notifmirror.android.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Round-trip tests for the wire codec. These mirror the macOS-side XCTest
 * suite (mac/NotifMirrorTests/WireCodecTests.swift) so a protocol change on
 * either platform is caught by the other platform's CI.
 */
class WireCodecTest {

    private fun roundTrip(message: WireMessage): WireMessage =
        WireCodec.decode(WireCodec.encode(message))

    @Test
    fun helloRoundTrip() {
        val m = roundTrip(
            WireMessage.Hello(
                secret = "s3cr3t",
                deviceName = "Pixel 8",
                proto = 2,
                features = listOf("clip", "media", "file")
            )
        )
        assertTrue(m is WireMessage.Hello)
        m as WireMessage.Hello
        assertEquals("s3cr3t", m.secret)
        assertEquals("Pixel 8", m.deviceName)
        assertEquals(2, m.proto)
        assertEquals(listOf("clip", "media", "file"), m.features)
    }

    @Test
    fun helloRoundTripEmptyFeatures() {
        val m = roundTrip(WireMessage.Hello("k", "d", 1, emptyList()))
        assertTrue(m is WireMessage.Hello)
        assertTrue((m as WireMessage.Hello).features.isEmpty())
    }

    @Test
    fun helloAckRoundTrip() {
        val m = roundTrip(
            WireMessage.HelloAck(
                accepted = true,
                serverName = "MacBook",
                features = listOf("clip"),
                dataPort = 0
            )
        )
        assertTrue(m is WireMessage.HelloAck)
        m as WireMessage.HelloAck
        assertTrue(m.accepted)
        assertEquals("MacBook", m.serverName)
        assertEquals(listOf("clip"), m.features)
        assertEquals(0, m.dataPort)
    }

    @Test
    fun postedEncodesExpectedJson() {
        // `posted` is phone → Mac only, so the Android codec encodes it but
        // intentionally never decodes it (the Mac side owns that).
        val json = WireCodec.encode(
            WireMessage.Posted(
                key = "0|com.whatsapp|12345|null|10123",
                pkg = "com.whatsapp",
                app = "WhatsApp",
                title = "Ali",
                text = "Hey, are you around?",
                subText = null,
                appIcon = "iVBORw0KGgo=",
                largeIcon = null,
                picture = null,
                postTime = 1_710_000_000_000,
                silent = false,
                actions = listOf(
                    ActionDescriptor("0", "Reply", true),
                    ActionDescriptor("1", "Mark as read", false)
                )
            )
        )
        assertTrue(json.contains("\"t\":\"posted\""))
        assertTrue(json.contains("\"key\":\"0|com.whatsapp|12345|null|10123\""))
        assertTrue(json.contains("\"app\":\"WhatsApp\""))
        assertTrue(json.contains("\"title\":\"Ali\""))
        assertTrue(json.contains("\"actions\":[{\"id\":\"0\",\"title\":\"Reply\",\"isReply\":true}"))
        // Phone→Mac only: decoding a `posted` frame must not crash and yields Unknown.
        val decoded = WireCodec.decode(json)
        assertTrue(decoded is WireMessage.Unknown)
    }

    @Test
    fun removedAndDismissRoundTrip() {
        assertTrue(roundTrip(WireMessage.Removed("key1")) is WireMessage.Removed)
        assertTrue(roundTrip(WireMessage.Dismiss("key2")) is WireMessage.Dismiss)
    }

    @Test
    fun actionRoundTrip() {
        val withText = roundTrip(WireMessage.Action("k", "0", "hello"))
        assertTrue(withText is WireMessage.Action)
        assertEquals("hello", (withText as WireMessage.Action).text)

        val withoutText = roundTrip(WireMessage.Action("k", "0", null))
        assertTrue(withoutText is WireMessage.Action)
        assertNull((withoutText as WireMessage.Action).text)
    }

    @Test
    fun clipRoundTrip() {
        val m = roundTrip(WireMessage.Clip("hello world", "mac", 42))
        assertTrue(m is WireMessage.Clip)
        m as WireMessage.Clip
        assertEquals("hello world", m.text)
        assertEquals("mac", m.origin)
        assertEquals(42, m.seq)
    }

    @Test
    fun mediaStateRoundTrip() {
        val m = roundTrip(
            WireMessage.MediaState(
                pkg = "com.spotify.music",
                app = "Spotify",
                title = "Midnight City",
                artist = "M83",
                album = "Hurry Up",
                artwork = null,
                playing = true,
                positionMs = 73_400,
                durationMs = 241_000,
                canPause = true,
                canSkipNext = true,
                canSkipPrev = false,
                volume = 6,
                maxVolume = 15,
                updatedAt = 1_710_000_000_000
            )
        )
        assertTrue(m is WireMessage.MediaState)
        m as WireMessage.MediaState
        assertEquals("com.spotify.music", m.pkg)
        assertEquals("Midnight City", m.title)
        assertTrue(m.playing)
        assertEquals(73_400, m.positionMs)
        assertEquals(6, m.volume)
        assertEquals(15, m.maxVolume)
    }

    @Test
    fun mediaCmdRoundTrip() {
        val m = roundTrip(WireMessage.MediaCmd("vol_set", 8))
        assertTrue(m is WireMessage.MediaCmd)
        m as WireMessage.MediaCmd
        assertEquals("vol_set", m.cmd)
        assertEquals(8, m.value)
    }

    @Test
    fun batteryStateRoundTrip() {
        val m = roundTrip(
            WireMessage.BatteryState(
                level = 87,
                charging = true,
                status = "charging",
                plugged = "ac",
                temperatureC = 32.5,
                voltageMv = 4250,
                low = false,
                updatedAt = 1_710_000_000_000
            )
        )
        assertTrue(m is WireMessage.BatteryState)
        m as WireMessage.BatteryState
        assertEquals(87, m.level)
        assertTrue(m.charging)
        assertEquals("charging", m.status)
        assertEquals(32.5, m.temperatureC!!, 0.001)
        assertEquals(4250, m.voltageMv)
    }

    @Test
    fun batteryStateRoundTripNulls() {
        val m = roundTrip(
            WireMessage.BatteryState(-1, false, "unknown", "none", null, null, false, 0)
        )
        assertTrue(m is WireMessage.BatteryState)
        assertNull((m as WireMessage.BatteryState).temperatureC)
        assertNull(m.voltageMv)
    }

    @Test
    fun fileTransferRoundTrip() {
        assertTrue(
            roundTrip(WireMessage.FileOffer("x1", "photo.jpg", 2_847_392, "image/jpeg", "abc"))
                is WireMessage.FileOffer
        )
        assertTrue(roundTrip(WireMessage.FileAccept("x1")) is WireMessage.FileAccept)
        assertTrue(roundTrip(WireMessage.FileReject("x1", "too_big")) is WireMessage.FileReject)
        assertTrue(roundTrip(WireMessage.FileChunk("x1", 0, "aGVsbG8=", false)) is WireMessage.FileChunk)
        assertTrue(roundTrip(WireMessage.FileDone("x1")) is WireMessage.FileDone)
        assertTrue(roundTrip(WireMessage.FileAck("x1", true, null)) is WireMessage.FileAck)
        assertTrue(roundTrip(WireMessage.FileCancel("x1", "user_cancelled")) is WireMessage.FileCancel)
    }

    @Test
    fun fsBrowseRoundTrip() {
        assertTrue(roundTrip(WireMessage.FsList("r1", "/sdcard")) is WireMessage.FsList)
        val listResult = roundTrip(
            WireMessage.FsListResult(
                "r1", "/sdcard",
                listOf(
                    WireMessage.FsEntry("Camera", "dir", 0, 1_714_074_123),
                    WireMessage.FsEntry("IMG_0001.jpg", "file", 2_456_123, 1_714_074_124)
                ),
                null
            )
        )
        assertTrue(listResult is WireMessage.FsListResult)
        assertEquals(2, (listResult as WireMessage.FsListResult).entries.size)

        assertTrue(roundTrip(WireMessage.FsDelete("r2", "/a")) is WireMessage.FsDelete)
        assertTrue(roundTrip(WireMessage.FsMkdir("r3", "/b")) is WireMessage.FsMkdir)
        assertTrue(roundTrip(WireMessage.FsRename("r4", "/a", "/b")) is WireMessage.FsRename)
        assertTrue(roundTrip(WireMessage.FsOpResult("r2", true, null)) is WireMessage.FsOpResult)
        assertTrue(roundTrip(WireMessage.FsDisk("r5", "/sdcard")) is WireMessage.FsDisk)
        assertTrue(
            roundTrip(WireMessage.FsDiskResult("r5", 39_929_436_672, 108_736_512_000, null))
                is WireMessage.FsDiskResult
        )
        assertTrue(roundTrip(WireMessage.FsDu("r6", "/sdcard")) is WireMessage.FsDu)
        assertTrue(
            roundTrip(
                WireMessage.FsDuResult("r6", "/sdcard", 42_949_672_960, emptyList(), null)
            ) is WireMessage.FsDuResult
        )
        assertTrue(roundTrip(WireMessage.FsRead("r7", "/a.txt")) is WireMessage.FsRead)
        assertTrue(roundTrip(WireMessage.FsReadResult("r7", 12_345, null)) is WireMessage.FsReadResult)
        assertTrue(roundTrip(WireMessage.FsWrite("r8", "/a.txt", 12_345)) is WireMessage.FsWrite)
        assertTrue(roundTrip(WireMessage.FsWriteReady("r8", null)) is WireMessage.FsWriteReady)
        assertTrue(roundTrip(WireMessage.FsChunk("r8", 0, "aGk=", true)) is WireMessage.FsChunk)
        assertTrue(roundTrip(WireMessage.FsCancel("r9", "abandoned")) is WireMessage.FsCancel)
    }

    @Test
    fun testRequestRoundTrip() {
        val m = roundTrip(WireMessage.TestRequest("r7"))
        assertTrue(m is WireMessage.TestRequest)
        assertEquals("r7", (m as WireMessage.TestRequest).reqId)
    }

    @Test
    fun pingPongAndErrorRoundTrip() {
        assertTrue(roundTrip(WireMessage.Ping) is WireMessage.Ping)
        assertTrue(roundTrip(WireMessage.Pong) is WireMessage.Pong)
        val m = roundTrip(WireMessage.Error("bad_secret", "auth failed"))
        assertTrue(m is WireMessage.Error)
        assertEquals("bad_secret", (m as WireMessage.Error).code)
    }

    @Test
    fun unknownTypeDecodesAsUnknown() {
        val decoded = WireCodec.decode("""{"t":"future_type","v":2,"foo":1}""")
        assertTrue(decoded is WireMessage.Unknown)
        assertEquals("future_type", (decoded as WireMessage.Unknown).type)
    }

    @Test
    fun everyFrameCarriesVersionField() {
        for (m in listOf<WireMessage>(
            WireMessage.Hello("k", "d", 2, emptyList()),
            WireMessage.Posted(
                key = "k", pkg = "p", app = "a", title = null, text = null,
                subText = null, appIcon = null, largeIcon = null, picture = null,
                postTime = 0, silent = false, actions = emptyList()
            ),
            WireMessage.Ping
        )) {
            val json = WireCodec.encode(m)
            assertTrue("frame must carry v=$PROTO_VERSION", json.contains("\"v\":$PROTO_VERSION"))
        }
    }
}
