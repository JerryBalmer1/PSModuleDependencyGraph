# Default rendering settings for Save-PSModuleDependencyGraphHtml.
#
# To change any of them, copy the keys you want into your own .psd1 and pass it
# with -ConfigPath. Your file is merged over this one: hashtables key by key,
# NodeGroups by Name, and any other list is replaced whole.
#
# The graph gives every node a Type; the page uses it, lower-cased, as the
# node's group. How a group looks lives here, so the page can draw any graph
# whose nodes carry these group names. Colours are #rrggbb.
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

    # One entry per node Type, in legend and Show order.
    #   Shape:  box, ellipse, circle, database, text, diamond, dot, star, triangle, hexagon, square
    #   Dashed: draw the border dashed
    NodeGroups = @(
        @{ Name = 'public'; Label = 'Public'; Color = '#22d3ee'; Shape = 'box' }
        @{ Name = 'private'; Label = 'Private'; Color = '#3b82f6'; Shape = 'box' }
        @{ Name = 'unresolved'; Label = 'Unresolved (private, never called)'; Color = '#ff4d4f'; Shape = 'box'; Dashed = $true }
        @{ Name = 'external'; Label = 'External command'; Color = '#e040fb'; Shape = 'box' }
        @{ Name = 'class'; Label = 'Class'; Color = '#f2c14e'; Shape = 'box' }
        @{ Name = 'enum'; Label = 'Enum'; Color = '#6ddf6d'; Shape = 'box' }
        @{ Name = 'script'; Label = 'Script top level'; Color = '#94a3b8'; Shape = 'ellipse' }
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
        # An external command that was not found on this machine: its border is
        # dashed, and this is written under its name.
        NotFoundText = 'not found'
    }

    Edges      = @{
        Color          = '#5d6b80'
        Width          = 1.2
        ArrowScale     = 0.6
        # dynamic, continuous, discrete, diagonalCross, straightCross, horizontal,
        # vertical, curvedCW, curvedCCW, cubicBezier
        Curve          = 'cubicBezier'
        Roundness      = 0.45
        AmbiguousColor = '#f2c14e'
        ExternalColor  = '#b04bc4'
        InheritsColor  = '#f2c14e'
        OutputsColor   = '#f2c14e'
    }

    # Layered layout: each caller comes before what it calls.
    Layout     = @{
        # RightToLeft, LeftToRight, TopToBottom or BottomToTop. The page can
        # switch between them.
        Direction   = 'LeftToRight'
        # directed: by call direction. hubsize: most-connected node first.
        SortMethod  = 'directed'
        # LevelSeparation: between layers. NodeSpacing: between nodes in one
        # layer. TreeSpacing: between unconnected groups. RightToLeft uses the
        # LeftToRight spacing and BottomToTop the TopToBottom spacing.
        LeftToRight = @{ LevelSeparation = 330; NodeSpacing = 50; TreeSpacing = 70 }
        TopToBottom = @{ LevelSeparation = 110; NodeSpacing = 300; TreeSpacing = 260 }
    }

    # Which node Types show when the page opens. Each has a box on the page.
    Show       = @{
        Types = @('public', 'private', 'unresolved', 'external', 'class', 'enum', 'script')
    }

    # The right-click menu on a node, top to bottom.
    #   Action: Open (follow Target as a link) or Copy (put Target on the clipboard).
    #   When:   Always, HasFile (nodes with a source file) or HasModule (commands
    #           with a known module).
    #   Target placeholders:
    #     {name}         function, class, enum or command name
    #     {module}       the module an external command belongs to
    #     {path}         file relative to the module
    #     {fullPath}     full file path, as the operating system writes it
    #     {fileUrlPath}  full file path with forward slashes, URL-encoded
    #     {startLine}    first line of the definition
    #     {endLine}      last line of the definition
    NodeMenu   = @(
        @{ Label = 'Show in VS Code'; Action = 'Open'; Target = 'vscode://file/{fileUrlPath}:{startLine}'; When = 'HasFile' }
        @{ Label = 'Copy path and line'; Action = 'Copy'; Target = '{fullPath}:{startLine}'; When = 'HasFile' }
        @{ Label = 'Copy name'; Action = 'Copy'; Target = '{name}'; When = 'Always' }
        @{ Label = 'Copy module name'; Action = 'Copy'; Target = '{module}'; When = 'HasModule' }
    )
}
