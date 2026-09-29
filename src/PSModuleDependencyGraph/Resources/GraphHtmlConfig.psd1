# Default rendering settings for Save-PSModuleDependencyGraphHtml.
#
# To change any of them, copy the keys you want into your own .psd1 and pass it
# with -ConfigPath. Your file is merged over this one: hashtables key by key,
# NodeGroups by Name, and any other list is replaced whole.
#
# The graph only says which group each node is in. How a group looks lives
# here, so the page can draw any graph whose nodes carry these group names.
# Colours are #rrggbb.
@{
    # The page around the graph.
    Theme      = @{
        Background = '#12161c'
        Panel      = '#1a1f27'
        PanelAlt   = '#222834'
        Border     = '#2e3644'
        Text       = '#e6edf6'
        TextDim    = '#98a4b6'
        Accent     = '#4da3ff'
        FontFamily = '"Segoe UI", -apple-system, BlinkMacSystemFont, Roboto, Helvetica, Arial, sans-serif'
        FontSize   = 13
    }

    # One entry per kind of node, in legend order.
    #   Shape:  box, ellipse, circle, database, text, diamond, dot, star, triangle, hexagon, square
    #   Dashed: draw the border dashed
    NodeGroups = @(
        @{ Name = 'public'; Label = 'Public (exported)'; Color = '#4da3ff'; Shape = 'box' }
        @{ Name = 'private'; Label = 'Private'; Color = '#8a96a8'; Shape = 'box' }
        @{ Name = 'dangling'; Label = 'Private, never called'; Color = '#c678dd'; Shape = 'box'; Dashed = $true }
        @{ Name = 'script'; Label = 'Script top level'; Color = '#9b8cff'; Shape = 'ellipse' }
        @{ Name = 'class'; Label = 'Class'; Color = '#f2c14e'; Shape = 'box' }
        @{ Name = 'enum'; Label = 'Enum'; Color = '#6ddf6d'; Shape = 'box' }
        @{ Name = 'unresolved'; Label = 'Unresolved command'; Color = '#ff4d4f'; Shape = 'box'; Dashed = $true }
    )

    Nodes      = @{
        # Labels wider than this wrap.
        MaxWidth     = 280
        BorderWidth  = 1.5
        PaddingY     = 7
        PaddingX     = 10
        # How much of the group colour goes into the fill, 0 to 1. The rest is
        # the background. Fills are solid so an edge never shows through a label.
        FillStrength = 0.2
    }

    Edges      = @{
        Color           = '#5d6b80'
        Width           = 1.2
        ArrowScale      = 0.6
        # dynamic, continuous, discrete, diagonalCross, straightCross, horizontal,
        # vertical, curvedCW, curvedCCW, cubicBezier
        Curve           = 'cubicBezier'
        Roundness       = 0.45
        AmbiguousColor  = '#f2c14e'
        UnresolvedColor = '#ff4d4f'
        InheritsColor   = '#f2c14e'
    }

    # Layered layout: each caller comes before what it calls.
    Layout     = @{
        # LeftToRight or TopToBottom. The page can switch between them.
        Direction   = 'LeftToRight'
        # directed: by call direction. hubsize: most-connected node first.
        SortMethod  = 'directed'
        # LevelSeparation: between layers. NodeSpacing: between nodes in one
        # layer. TreeSpacing: between unconnected groups.
        LeftToRight = @{ LevelSeparation = 330; NodeSpacing = 50; TreeSpacing = 70 }
        TopToBottom = @{ LevelSeparation = 110; NodeSpacing = 300; TreeSpacing = 260 }
    }

    # What the page shows when it opens. Both can be toggled on the page.
    Show       = @{
        Unresolved   = $true
        ExportedOnly = $false
    }

    # The right-click menu on a node, top to bottom.
    #   Action: Open (follow Target as a link) or Copy (put Target on the clipboard).
    #   When:   Always, or HasFile (only for nodes with a source file).
    #   Target placeholders:
    #     {name}         function, class or enum name
    #     {path}         file relative to the module
    #     {fullPath}     full file path, as the operating system writes it
    #     {fileUrlPath}  full file path with forward slashes, URL-encoded
    #     {startLine}    first line of the definition
    #     {endLine}      last line of the definition
    NodeMenu   = @(
        @{ Label = 'Show in VS Code'; Action = 'Open'; Target = 'vscode://file/{fileUrlPath}:{startLine}'; When = 'HasFile' }
        @{ Label = 'Copy path and line'; Action = 'Copy'; Target = '{fullPath}:{startLine}'; When = 'HasFile' }
        @{ Label = 'Copy name'; Action = 'Copy'; Target = '{name}'; When = 'Always' }
    )
}
