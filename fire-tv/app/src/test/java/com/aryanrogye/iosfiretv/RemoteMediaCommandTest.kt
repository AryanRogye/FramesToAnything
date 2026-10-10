package com.aryanrogye.iosfiretv

import org.junit.Assert.*
import org.junit.Test

class RemoteMediaCommandTest {
    @Test fun seekingRequiresNegotiationAndKnownCommands() {
        assertTrue(RemoteMediaCommand.allowed(RemoteMediaCommand.TOGGLE, false))
        assertFalse(RemoteMediaCommand.allowed(RemoteMediaCommand.FORWARD_10, false))
        assertFalse(RemoteMediaCommand.allowed(RemoteMediaCommand.BACKWARD_10, false))
        assertTrue(RemoteMediaCommand.allowed(RemoteMediaCommand.FORWARD_10, true))
        assertTrue(RemoteMediaCommand.allowed(RemoteMediaCommand.BACKWARD_10, true))
        assertFalse(RemoteMediaCommand.allowed("set_time", true))
        assertFalse(RemoteMediaCommand.allowed("seek_forward_30", true))
    }

    @Test fun mediaSeekKeysDoNotChangeDpadNavigationOrToggle() {
        assertEquals(RemoteMediaCommand.BACKWARD_10, RemoteMediaCommand.forKey(89))
        assertEquals(RemoteMediaCommand.FORWARD_10, RemoteMediaCommand.forKey(90))
        for (key in listOf(79, 85, 126, 127)) assertEquals(RemoteMediaCommand.TOGGLE, RemoteMediaCommand.forKey(key))
        for (key in listOf(19, 20, 21, 22, 23, 87, 88)) assertNull(RemoteMediaCommand.forKey(key))
    }
}
