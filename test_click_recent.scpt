-- Test script to click a Recent item using Accessibility
-- Run with: osascript test_click_recent.scpt "TextEdit"

on run argv
    if (count of argv) < 1 then
        set appName to "TextEdit"
    else
        set appName to item 1 of argv
    end if
    
    log "Attempting to click Recent item for: " & appName
    
    tell application "System Events"
        set dockProcess to process "Focus Dock"
        
        -- Get the main dock window (the floating panel)
        set dockWindow to window 1 of dockProcess
        
        -- Find the button (or UI element) with the accessibility identifier we set
        try
            set recentButton to first button of dockWindow whose value of attribute "AXIdentifier" contains ("recent-" & appName)
            log "Found Recent button for " & appName
            
            -- Click it
            click recentButton
            log "Click sent to Recent " & appName
            
        on error errMsg
            log "Could not find or click the Recent item for " & appName & ": " & errMsg
            
            -- Fallback: try to find by name in the dock
            try
                set recentItem to first UI element of dockWindow whose name contains appName
                click recentItem
                log "Fallback click sent using name"
            on error
                log "Fallback also failed"
            end try
        end try
    end tell
end run