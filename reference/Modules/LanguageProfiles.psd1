# PowerShell Data File for Breakitdown Language Profiles

@{
    # PowerShell Profile
    '.ps1' = @{
        LanguageName = "PowerShell"
        # Use [ordered] to guarantee pattern matching precedence
        Categories = @{
            # More specific patterns first
            Attribute = '(?i)^\s*\[' # Starts with [ (e.g., [CmdletBinding()])
            ParamBlock = '(?i)^\s*param\s*\(' # Starts with param(
            ParamBlockEnd = '(?i)^\s*\)\s*$' # Line is just )
            FunctionDefinition = '(?i)^\s*function\s+' # Starts with function keyword
            WorkflowDefinition = '(?i)^\s*workflow\s+' # Starts with workflow keyword
            FilterDefinition = '(?i)^\s*filter\s+' # Starts with filter keyword
            ClassDefinition = '(?i)^\s*(class|enum)\s+' # Starts with class or enum
            ConfigurationDefinition = '(?i)^\s*configuration\s+' # Starts with configuration
            Logging = '(?i)^\s*Write-(Verbose|Debug|Warning|Error|Information)\b' # Excludes Write-Host
            UsingStatement = '(?i)^\s*using\s+(module|namespace|assembly)\b' # Starts with using module/namespace/assembly
            VariableAssignment = '^\s*\$((global|script|local|private|variable):)?[a-zA-Z_][\w-]*\s*(=|\+=|-=|\*=|/=|%=)\s*' # Starts with $var = or other assignment operators
            ControlFlowConditionalCombined = '(?i)^\s*\}\s*(else|elseif)\b' # e.g., } else { or } elseif (
            ControlFlowConditional = '(?i)^\s*(if|elseif|switch)\b' # Starts with if, elseif, switch (else handled above)
            ControlFlowLoop = '(?i)^\s*(for|foreach|while|do)\b' # Starts with for, while etc.
            ErrorHandlingCombined = '(?i)^\s*\}\s*(catch|finally)\b' # e.g., } catch {
            ErrorHandling = '(?i)^\s*(try|trap)\b' # Starts with try, trap (catch/finally handled above)
            # --- Block Structures ---
            IO = '(?i)^\s*(Import-Module|Get-Content|Set-Content|Add-Content|Clear-Content|Get-Item|Test-Path|Resolve-Path|Split-Path|Join-Path|New-Item|Remove-Item)\b'
            BlockStructure = '(?i)^\s*(begin|process|end|dynamicparam)\s*\{' # Starts with begin/process/end/dynamicparam {
            # --- General Command Invocation ---
            CommandInvocation = '^\s*[a-zA-Z][\w-]*-[a-zA-Z][\w-]*\b' # Matches Verb-Noun, including Write-Host
            # --- Comment (often pre-filtered but good to have) ---
            Comment = '^\s*#' # Starts with #
            # --- General Block Delimiter (less specific, checked later) ---
            # Allows for trailing whitespace and an optional comment after the brace
            BlockDelimiter = '^\s*(\{|\})\s*(#.*)?$' # REVISED regex
            DotSourcing = '^\s*\.\s+'
        }
    }

    # Aliases for PowerShell file types
    '.psd1' = '.ps1' # Point to the .ps1 profile
    '.psm1' = '.ps1' # Point to the .ps1 profile

    # Python Profile
    '.py' = @{
        LanguageName = "Python"
        Categories =@{
            # Python is case-sensitive
            Import = '^\s*(import|from)\s+'
            Decorator = '^\s*@'
            FunctionDefinition = '^\s*def\s+'
            FunctionDefinitionEnd = '^\s*\):' # NEW: Matches closing ): of function def
            ClassDefinition = '^\s*class\s+'
            VariableAssignment = '^\s*[a-zA-Z_][\w]*\s*(=|\+=|-=|\*=|/=|%=|:=)\s*' # Includes walrus
            ContextManager = '^\s*with\b' # For 'with' statements
            ControlFlowConditional = '^\s*(if|elif|else)\b.*:'
            ControlFlowLoop = '^\s*(for|while)\b.*:'
            ErrorHandling = '^\s*(try|except|finally|assert)\b' # Removed 'with'
            ExpressionStatement = '^\s*[a-zA-Z_][\w]*(\.[a-zA-Z_][\w]*|\(.*\)).*' # Matches name.something or name(...)
            Comment = '^\s*#'
            Docstring = '^\s*("""|\x27\x27\x27)'
        }
    }
    '.rs' = @{ # Example for Rust
            LanguageName = "Rust"
            Categories = @{
                Attribute = '^\s*#\[' # Starts with #[
                Import = '^\s*(use|mod|extern\s+crate)\b' # Starts with use, mod, extern crate
                FunctionDefinition = '^\s*(pub\s+)?(async\s+)?(unsafe\s+)?(extern\s+)?fn\s+' # Starts with fn (and modifiers)
                StructDefinition = '^\s*(pub\s+)?struct\s+' # Starts with struct
                EnumDefinition = '^\s*(pub\s+)?enum\s+' # Starts with enum
                TraitDefinition = '^\s*(pub\s+)?(unsafe\s+)?trait\s+' # Starts with trait
                ImplBlock = '^\s*(unsafe\s+)?impl\b' # Starts with impl
                StaticVar = '^\s*(pub\s+)?static\s+(ref\s+)?(mut\s+)?' # Starts with static
                Constant = '^\s*(pub\s+)?const\s+' # Starts with const
                TypeAlias = '^\s*(pub\s+)?type\s+' # Starts with type
                MacroDefinition = '^\s*macro_rules!' # Starts with macro_rules!
                VariableAssignment = '^\s*let\s+(mut\s+)?[a-zA-Z_][\w]*\s*=' # Starts with let var = or let mut var =
                ControlFlowConditional = '^\s*(if|match)\b' # Starts with if, match
                ControlFlowLoop = '^\s*(loop|for|while)\b' # Starts with loop, for, while
                Comment = '^\s*//' # Starts with //
                DocComment = '^\s*(///|//!|\/\*\*|\/\*!)' # Starts with /// or //! etc.
            }
        }
        
        '.cpp' =@{ # Example for C++
                LanguageName = "C++"
                Categories =@{
                    Preprocessor = '^\s*#' # Starts with # (e.g., #include, #define)
                    Namespace = '^\s*namespace\b' # Starts with namespace
                    UsingDirective = '^\s*using\s+namespace\b' # Starts with using namespace
                    UsingDeclaration = '^\s*using\s+[a-zA-Z_:]' # Starts with using Some::Identifier;
                    ClassDefinition = '^\s*(class|struct|union)\s+' # Starts with class, struct, union
                    EnumDefinition = '^\s*(enum\s+(class|struct)\s+|enum\s+)\s*[a-zA-Z_]' # Starts with enum or enum class/struct
                    FunctionDefinition = '^\s*([a-zA-Z_][\w<>,:\*&\s]+\s+)+[a-zA-Z_][\w]*\s*\([^)]*\)\s*(const|noexcept|override|final)*\s*\{?' # Complex: Matches return type(s) name(params){ - needs refinement
                    VariableDeclaration = '^\s*([a-zA-Z_][\w<>,:\*&\s]+\s+)+[a-zA-Z_][\w]*\s*(\[.*\])?\s*(=|{)?' # Complex: Matches type name = or type name{ - needs refinement
                    ControlFlowConditional = '^\s*(if|else\s+if|else|switch)\b' # Starts with if, else, switch
                    ControlFlowLoop = '^\s*(for|while|do)\b' # Starts with for, while, do
                    ErrorHandling = '^\s*(try|catch)\b' # Starts with try, catch
                    Comment = '^\s*//' # Starts with //
                    BlockCommentStart = '^\s*/\*' # Starts with /* (often filtered)
                }
            }

}
