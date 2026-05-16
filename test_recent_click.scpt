-- Test script: Use Apple Accessibility (System Events) to find and click a "Recent" item in Focus Dock
-- Usage: osascript test_recent_click.scpt "TextEdit"

on run argv
    if (count of argv) < 1 then
        set targetName to "TextEdit"
    else
        set targetName to item 1 of argv
    end if

    log "=== Starting AX test for Recent item: " & targetName & " ==="

    tell application "System Events"
        -- Get the Focus Dock process (the custom NSPanel)
        set dockProc to first application process whose name is "Focus Dock"

        log "Found Focus Dock process. Windows: " & (count of windows of dockProc)

        -- The main dock chrome is usually window 1 (the floating panel)
        set mainWindow to window 1 of dockProc

        log "Main window name: " & (name of mainWindow)

        -- Strategy 1: Find by the accessibilityIdentifier we set ("recent-TextEdit")
        try
            set recentElement to first UI element of mainWindow whose value of attribute "AXIdentifier" contains ("recent-" & targetName)
            log "SUCCESS: Found element by accessibilityIdentifier"
            log "Element role: " & (role of recentElement) & ", name: " & (name of recentElement)
            
            -- Perform the click
            click recentElement
            log "Click action sent via AX to Recent " & targetName
            return "Clicked via identifier"
        on error errMsg
            log "Could not find by accessibilityIdentifier: " & errMsg
        end try

        -- Strategy 2: Search by name (the .help() or title of the tile)
        try
            set recentElement to first UI element of mainWindow whose name contains targetName
            log "Found element by name containing " & targetName
            log "Element role: " & (role of recentElement)
            
            click recentElement
            log "Click action sent via AX (by name)"
            return "Clicked via name"
        on error errMsg
            log "Could not find by name: " & errMsg
        end try

        -- Strategy 3: Dump some elements for debugging (first 10)
        log "Dumping first 10 UI elements in the window for diagnosis..."
        set elemCount to count of UI elements of mainWindow
        log "Total UI elements: " & elemCount
        
        repeat with i from 1 to (minimum of {elemCount, 10})
            try
                set el to UI element i of mainWindow
                set elRole to role of el
                set elName to name of el
                set elIdent to ""
                try
                    set elIdent to value of attribute "AXIdentifier" of el
                end try
                log "  [" & i & "] role=" & elRole & " name=" & elName & " identifier=" & elIdent
            end try
        end repeat

        log "=== AX test completed without successful click ==="
    end tell
end run