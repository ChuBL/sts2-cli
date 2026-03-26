#!/bin/bash
# setup.sh — Copy game DLLs from Steam installation to lib/
#
# Prerequisites:
#   - Slay the Spire 2 installed via Steam
#   - .NET 9+ SDK (ARM64 for Apple Silicon, x64 for Intel/Linux)
#
# Usage:
#   ./setup.sh                    # Auto-detect Steam path
#   ./setup.sh /path/to/game      # Manual game directory

set -e

# ── Locate game directory ──

GAME_DIR="$1"

if [ -z "$GAME_DIR" ]; then
    # Auto-detect based on platform
    case "$(uname -s)" in
        Darwin)
            GAME_DIR="$HOME/Library/Application Support/Steam/steamapps/common/Slay the Spire 2/SlayTheSpire2.app/Contents/Resources/data_sts2_macos_arm64"
            if [ ! -d "$GAME_DIR" ]; then
                # Try x86_64
                GAME_DIR="$HOME/Library/Application Support/Steam/steamapps/common/Slay the Spire 2/SlayTheSpire2.app/Contents/Resources/data_sts2_macos_x86_64"
            fi
            ;;
        Linux)
            GAME_DIR="$HOME/.steam/steam/steamapps/common/Slay the Spire 2"
            if [ ! -d "$GAME_DIR" ]; then
                GAME_DIR="$HOME/.local/share/Steam/steamapps/common/Slay the Spire 2"
            fi
            ;;
        MINGW*|MSYS*|CYGWIN*)
            GAME_DIR="C:/Program Files (x86)/Steam/steamapps/common/Slay the Spire 2"
            ;;
    esac
fi

if [ ! -d "$GAME_DIR" ]; then
    echo "❌ Game directory not found: $GAME_DIR"
    echo ""
    echo "Usage: ./setup.sh /path/to/game/data"
    echo ""
    echo "On macOS, this is usually:"
    echo "  ~/Library/Application Support/Steam/steamapps/common/Slay the Spire 2/SlayTheSpire2.app/Contents/Resources/data_sts2_macos_arm64"
    exit 1
fi

echo "📁 Game directory: $GAME_DIR"

# ── Copy DLLs ──

mkdir -p lib

DLLS=(
    "sts2.dll"
    "SmartFormat.dll"
    "SmartFormat.ZString.dll"
    "Sentry.dll"
    "Steamworks.NET.dll"
    "MonoMod.Backports.dll"
    "MonoMod.ILHelpers.dll"
    "0Harmony.dll"
    "System.IO.Hashing.dll"
)

echo ""
echo "📦 Copying DLLs to lib/..."
for dll in "${DLLS[@]}"; do
    src="$GAME_DIR/$dll"
    if [ -f "$src" ]; then
        cp "$src" "lib/$dll"
        echo "  ✓ $dll"
    else
        echo "  ✗ $dll not found at $src"
        # Try searching subdirectories
        found=$(find "$GAME_DIR" -name "$dll" -print -quit 2>/dev/null)
        if [ -n "$found" ]; then
            cp "$found" "lib/$dll"
            echo "    → found at $found"
        else
            echo "    ⚠ Skipped (may cause build errors)"
        fi
    fi
done

# Back up original sts2.dll
if [ -f "lib/sts2.dll" ] && [ ! -f "lib/sts2.dll.original" ]; then
    cp "lib/sts2.dll" "lib/sts2.dll.original"
    echo "  ✓ Backed up sts2.dll.original"
fi

# ── Detect .NET SDK ──

DOTNET=""
if [ -x "$HOME/.dotnet-arm64/dotnet" ]; then
    DOTNET="$HOME/.dotnet-arm64/dotnet"
elif command -v dotnet &>/dev/null; then
    DOTNET="dotnet"
fi

if [ -z "$DOTNET" ]; then
    echo ""
    echo "❌ .NET SDK not found."
    echo "   Install .NET 9+ from https://dotnet.microsoft.com/download"
    echo "   Or set DOTNET env var to your dotnet binary path."
    exit 1
fi

DOTNET_VERSION=$($DOTNET --version 2>/dev/null)
DOTNET_MAJOR=$(echo "$DOTNET_VERSION" | cut -d'.' -f1)

if [ -z "$DOTNET_MAJOR" ] || [ "$DOTNET_MAJOR" -lt 9 ] 2>/dev/null; then
    echo ""
    echo "❌ .NET SDK $DOTNET_VERSION is too old. .NET 9+ is required."
    echo "   Install .NET 9+ from https://dotnet.microsoft.com/download"
    exit 1
fi

echo ""
echo "🔧 .NET SDK: $DOTNET ($DOTNET_VERSION)"

# ── IL Patch sts2.dll ──

echo ""
echo "🔨 Applying IL patches to sts2.dll..."

# Create a temporary patching project
PATCH_DIR=$(mktemp -d)
# Use the installed .NET major version for the patcher project
NET_TFM="net${DOTNET_MAJOR}.0"

cat > "$PATCH_DIR/Patcher.csproj" << 'PROJ'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>DOTNET_TFM_PLACEHOLDER</TargetFramework>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Mono.Cecil" Version="0.11.6" />
  </ItemGroup>
</Project>
PROJ
sed -i.bak "s|DOTNET_TFM_PLACEHOLDER|${NET_TFM}|" "$PATCH_DIR/Patcher.csproj"
rm -f "$PATCH_DIR/Patcher.csproj.bak"

cat > "$PATCH_DIR/Program.cs" << 'CSHARP'
using System;
using System.IO;
using System.Linq;
using Mono.Cecil;
using Mono.Cecil.Cil;

var dllPath = args[0];
Console.WriteLine($"Patching {dllPath}...");

var resolver = new DefaultAssemblyResolver();
var libDir = Path.GetDirectoryName(dllPath)!;
resolver.AddSearchDirectory(libDir);
// Also search for GodotSharp.dll in the GodotStubs output (any net* TFM)
var stubsBase = Path.Combine(Path.GetDirectoryName(libDir)!, "GodotStubs", "bin", "Debug");
if (Directory.Exists(stubsBase))
    foreach (var d in Directory.GetDirectories(stubsBase, "net*"))
        resolver.AddSearchDirectory(d);
var module = ModuleDefinition.ReadModule(dllPath, new ReaderParameters {
    AssemblyResolver = resolver,
    ReadingMode = ReadingMode.Deferred  // Don't force-resolve all references upfront
});

int patches = 0;

// Patch 1: Task.Yield() — make YieldAwaitable.YieldAwaiter.IsCompleted return true
// This prevents async deadlocks in headless mode
foreach (var type in module.Types)
{
    foreach (var nested in type.NestedTypes)
    {
        foreach (var nested2 in nested.NestedTypes)
        {
            if (nested2.Name.Contains("YieldAwaiter") || nested2.Name == "<>c")
            {
                foreach (var method in nested2.Methods)
                {
                    if (method.Name == "get_IsCompleted" && method.Body != null)
                    {
                        var il = method.Body.GetILProcessor();
                        il.Body.Instructions.Clear();
                        il.Emit(OpCodes.Ldc_I4_1);
                        il.Emit(OpCodes.Ret);
                        patches++;
                        Console.WriteLine($"  Patched {type.Name}.{nested.Name}.{nested2.Name}.IsCompleted");
                    }
                }
            }
        }
    }
}

// Patch 2: WaitUntilQueueIsEmptyOrWaitingOnNonPlayerDrivenAction → return Task.CompletedTask
foreach (var type in module.Types)
{
    foreach (var method in type.Methods)
    {
        if (method.Name == "WaitUntilQueueIsEmptyOrWaitingOnNonPlayerDrivenAction" && method.Body != null)
        {
            var il = method.Body.GetILProcessor();
            il.Body.Instructions.Clear();
            // return Task.CompletedTask
            var taskType = module.ImportReference(typeof(System.Threading.Tasks.Task));
            var completedProp = module.ImportReference(
                typeof(System.Threading.Tasks.Task).GetProperty("CompletedTask")!.GetGetMethod()!);
            il.Emit(OpCodes.Call, completedProp);
            il.Emit(OpCodes.Ret);
            patches++;
            Console.WriteLine($"  Patched {type.Name}.{method.Name} → Task.CompletedTask");
        }
    }
}

// Patch 3: Neutralize.OnPlay — fix null cardPlay.Target in headless mode
// Adds PlayCardAction._headlessTarget (static field) + FillNullTarget(CardPlay) helper,
// then injects FillNullTarget(this.cardPlay) at the start of Neutralize.OnPlay.MoveNext.
try
{
    var pcaType = module.Types.FirstOrDefault(t => t.Name == "PlayCardAction");
    var cardPlayType = module.Types.FirstOrDefault(t => t.Name == "CardPlay");
    var neutralizeType = module.Types.FirstOrDefault(t => t.Name == "Neutralize");
    var creatureTypeDef = module.Types.FirstOrDefault(t =>
        t.FullName == "MegaCrit.Sts2.Core.Entities.Creatures.Creature");

    if (pcaType != null && cardPlayType != null && neutralizeType != null && creatureTypeDef != null)
    {
        var creatureTypeRef = module.ImportReference(creatureTypeDef);
        var cardPlayTypeRef = module.ImportReference(cardPlayType);

        // Find CardPlay.<Target>k__BackingField
        var targetBacking = cardPlayType.Fields.FirstOrDefault(f => f.Name == "<Target>k__BackingField");

        if (targetBacking != null)
        {
            // Make <Target>k__BackingField accessible from any assembly code
            targetBacking.Attributes = (targetBacking.Attributes
                & ~Mono.Cecil.FieldAttributes.FieldAccessMask)
                | Mono.Cecil.FieldAttributes.Public;
            Console.WriteLine("  Made <Target>k__BackingField public");

            // 1. Add static field: PlayCardAction._headlessTarget (Creature?)
            //    Guard against re-patching an already-patched DLL.
            var headlessField = pcaType.Fields.FirstOrDefault(f => f.Name == "_headlessTarget");
            if (headlessField == null)
            {
                headlessField = new FieldDefinition(
                    "_headlessTarget",
                    Mono.Cecil.FieldAttributes.Public | Mono.Cecil.FieldAttributes.Static,
                    creatureTypeRef);
                pcaType.Fields.Add(headlessField);
                Console.WriteLine("  Added PlayCardAction._headlessTarget");
            }
            else
            {
                Console.WriteLine("  PlayCardAction._headlessTarget already exists; skipping");
            }

            // 2. Add instance method: CardPlay.FillNullTarget()  ← on CardPlay so it can access private fields
            //    if (this.<Target>k__BackingField != null) return;
            //    if (PlayCardAction._headlessTarget == null) return;
            //    this.<Target>k__BackingField = PlayCardAction._headlessTarget;
            //    Guard against re-patching an already-patched DLL.
            var fillMethod = cardPlayType.Methods.FirstOrDefault(m => m.Name == "FillNullTarget");
            if (fillMethod == null)
            {
                fillMethod = new MethodDefinition(
                    "FillNullTarget",
                    Mono.Cecil.MethodAttributes.Public,    // instance method on CardPlay
                    module.TypeSystem.Void);

                var fillIL = fillMethod.Body.GetILProcessor();
                var retInstr = fillIL.Create(OpCodes.Ret);

                // if (this.Target != null) return
                fillIL.Emit(OpCodes.Ldarg_0);
                fillIL.Emit(OpCodes.Ldfld, targetBacking);
                fillIL.Emit(OpCodes.Brtrue, retInstr);

                // if (PlayCardAction._headlessTarget == null) return
                fillIL.Emit(OpCodes.Ldsfld, headlessField);
                fillIL.Emit(OpCodes.Brfalse, retInstr);

                // this.Target = PlayCardAction._headlessTarget
                fillIL.Emit(OpCodes.Ldarg_0);
                fillIL.Emit(OpCodes.Ldsfld, headlessField);
                fillIL.Emit(OpCodes.Stfld, targetBacking);

                fillIL.Append(retInstr);

                cardPlayType.Methods.Add(fillMethod);  // Add to CardPlay (owns the private field)
                Console.WriteLine("  Added CardPlay.FillNullTarget");
            }
            else
            {
                Console.WriteLine("  CardPlay.FillNullTarget already exists; skipping");
            }

            // 3. Inject call to FillNullTarget at start of Neutralize.<OnPlay>d__5.MoveNext
            var onPlaySM = neutralizeType.NestedTypes.FirstOrDefault(t => t.Name.Contains("OnPlay"));
            var moveNext = onPlaySM?.Methods.FirstOrDefault(m => m.Name == "MoveNext");
            var cardPlayField = onPlaySM?.Fields.FirstOrDefault(f => f.Name == "cardPlay");

            if (moveNext != null && moveNext.HasBody && cardPlayField != null)
            {
                // Guard: skip if FillNullTarget is already called (DLL already patched)
                var alreadyPatched = moveNext.Body.Instructions.Any(i =>
                    i.OpCode == OpCodes.Callvirt &&
                    i.Operand is MethodReference mr &&
                    mr.Name == "FillNullTarget");

                if (alreadyPatched)
                {
                    Console.WriteLine("  Neutralize.OnPlay.MoveNext already patched; skipping");
                }
                else
                {
                    var mnIL = moveNext.Body.GetILProcessor();
                    var first = moveNext.Body.Instructions[0];
                    var fillRef = module.ImportReference(fillMethod);
                    var cardPlayFieldRef = module.ImportReference(cardPlayField);

                    // Insert before first instruction: ldarg.0; ldfld cardPlay; callvirt FillNullTarget
                    // cardPlay is always non-null when OnPlay is called, so no null check needed
                    mnIL.InsertBefore(first, mnIL.Create(OpCodes.Ldarg_0));
                    mnIL.InsertBefore(first, mnIL.Create(OpCodes.Ldfld, cardPlayFieldRef));
                    mnIL.InsertBefore(first, mnIL.Create(OpCodes.Callvirt, fillRef));

                    patches++;
                    Console.WriteLine("  Patched Neutralize.OnPlay.MoveNext — FillNullTarget injected");
                }
            }
            else
            {
                Console.WriteLine("  WARN: Could not find Neutralize.<OnPlay>d__5.MoveNext or cardPlay field");
            }
        }
        else
        {
            Console.WriteLine("  WARN: Could not find CardPlay.<Target>k__BackingField");
        }
    }
    else
    {
        Console.WriteLine("  WARN: Could not find required types for Neutralize patch");
    }
}
catch (Exception ex)
{
    Console.WriteLine($"  WARN: Neutralize patch failed: {ex.Message}");
}

// Patch 4: Null-guard SaveManager.get_Instance and get_PrefsSave in Neutralize.MoveNext.
// In headless mode, SaveManager.Instance may be null or PrefsSave may not be loaded.
// We add: dup; brfalse popAndSkip after each potentially-null call,
// and insert pop; br skipTarget as the cleanup path.
try
{
    var neutralize4 = module.Types.FirstOrDefault(t => t.Name == "Neutralize");
    var onPlaySM4 = neutralize4?.NestedTypes.FirstOrDefault(t => t.Name.Contains("OnPlay"));
    var moveNext4 = onPlaySM4?.Methods.FirstOrDefault(m => m.Name == "MoveNext");

    if (moveNext4 != null && moveNext4.HasBody)
    {
        // --- Find all relevant instructions BEFORE any modifications ---
        Instruction? smCall = null;   // call SaveManager::get_Instance
        Instruction? pfCall = null;   // callvirt SaveManager::get_PrefsSave
        Instruction? bneUn = null;    // bne.un.s (FastMode != 1)
        Instruction? stloc2 = null;   // stloc.2 (stores adjusted delay)

        foreach (var instr in moveNext4.Body.Instructions)
        {
            if (instr.OpCode == OpCodes.Call
                && instr.Operand is MethodReference smRef
                && smRef.DeclaringType.Name == "SaveManager"
                && smRef.Name == "get_Instance")
            {
                smCall = instr;
            }
            else if (smCall != null && pfCall == null
                && instr.OpCode == OpCodes.Callvirt
                && instr.Operand is MethodReference pfRef
                && pfRef.DeclaringType.Name == "SaveManager"
                && pfRef.Name == "get_PrefsSave")
            {
                pfCall = instr;
            }
            else if (smCall != null && bneUn == null
                && (instr.OpCode == OpCodes.Bne_Un_S || instr.OpCode == OpCodes.Bne_Un))
            {
                bneUn = instr;
            }
            else if (bneUn != null && stloc2 == null
                && (instr.OpCode == OpCodes.Stloc_2
                    || instr.OpCode == OpCodes.Stloc_S
                    || instr.OpCode == OpCodes.Stloc))
            {
                stloc2 = instr; break;
            }
        }

        // Guard: skip if SaveManager null guard already injected (DLL already patched)
        var smCallIdx = smCall != null ? moveNext4.Body.Instructions.IndexOf(smCall) : -1;
        var alreadyPatched4 = smCall != null
            && smCallIdx + 1 < moveNext4.Body.Instructions.Count
            && moveNext4.Body.Instructions[smCallIdx + 1].OpCode == OpCodes.Dup;

        if (alreadyPatched4)
        {
            Console.WriteLine("  Neutralize.MoveNext SaveManager guards already patched; skipping");
        }
        else if (smCall != null && bneUn != null)
        {
            var skipTarget4 = (Instruction)bneUn.Operand; // instr after FastMode block
            var mnIL4 = moveNext4.Body.GetILProcessor();

            // Build cleanup path: pop (one dangling stack value) then jump to skipTarget
            var popNull4 = mnIL4.Create(OpCodes.Pop);
            var brToSkip4 = mnIL4.Create(OpCodes.Br, skipTarget4);
            mnIL4.InsertBefore(skipTarget4, brToSkip4);
            mnIL4.InsertBefore(brToSkip4, popNull4);

            // Non-null FastMode path: after stloc.2 we must jump OVER the cleanup
            if (stloc2 != null)
                mnIL4.InsertAfter(stloc2, mnIL4.Create(OpCodes.Br, skipTarget4));

            // Upgrade bne.un.s → bne.un (branch distance may grow after insertions)
            if (bneUn.OpCode == OpCodes.Bne_Un_S)
                bneUn.OpCode = OpCodes.Bne_Un;

            // Guard 1: null check for SaveManager.Instance
            // After call get_Instance: dup; brfalse popNull4
            mnIL4.InsertAfter(smCall, mnIL4.Create(OpCodes.Brfalse, popNull4));
            mnIL4.InsertAfter(smCall, mnIL4.Create(OpCodes.Dup));

            // Guard 2: null check for SaveManager.PrefsSave
            // After callvirt get_PrefsSave: dup; brfalse popNull4
            if (pfCall != null)
            {
                mnIL4.InsertAfter(pfCall, mnIL4.Create(OpCodes.Brfalse, popNull4));
                mnIL4.InsertAfter(pfCall, mnIL4.Create(OpCodes.Dup));
            }

            patches++;
            Console.WriteLine("  Patched Neutralize.MoveNext — SaveManager+PrefsSave null guards");
        }
        else
        {
            Console.WriteLine("  WARN: Could not find SaveManager.get_Instance or bne.un in Neutralize.MoveNext");
        }
    }
}
catch (Exception ex4)
{
    Console.WriteLine($"  WARN: SaveManager null-guard patch failed: {ex4.Message}");
}

Console.WriteLine($"Applied {patches} patches");
var outPath = dllPath + ".patched";
module.Write(outPath);
module.Dispose();
File.Delete(dllPath);
File.Move(outPath, dllPath);
Console.WriteLine("Done!");
CSHARP

REPO_DIR="$(pwd)"
cd "$PATCH_DIR"
$DOTNET run -- "$REPO_DIR/lib/sts2.dll" 2>&1
cd "$REPO_DIR"
rm -rf "$PATCH_DIR"

# ── Build ──

echo ""
echo "🏗️ Building..."
$DOTNET build Sts2Headless/Sts2Headless.csproj 2>&1 | tail -5

echo ""
echo "✅ Setup complete!"
echo ""
echo "To play:"
echo "  python3 python/play.py"
echo ""
echo "To run batch games:"
echo "  python3 python/play_full_run.py 10"
