import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.util.task.ConsoleTaskMonitor;
import java.util.HashSet;
import java.util.Set;

public class decomp_intents extends GhidraScript {
    private static final String[] TARGETS = {
        "WAIntentHandler",
        "handleSearchForMessages",
        "reallyHandleSearchForMessages",
        "resolveSendersForSearchForMessages",
        "resolveDateTimeRangeForSearchForMessages",
        "handleSendMessage",
        "resolveRecipientsForSendMessage",
        "INSearchForMessagesIntentResponse",
        "INSendMessageIntentResponse",
        "initWithCode_userActivity_",
        "ContinueInApp",
        "intentSendMessage"
    };

    @Override
    public void run() throws Exception {
        DecompInterface ifc = new DecompInterface();
        ifc.openProgram(currentProgram);
        ConsoleTaskMonitor monitor = new ConsoleTaskMonitor();
        FunctionManager fm = currentProgram.getFunctionManager();
        Set<Long> seen = new HashSet<>();
        int total = 0;
        println("############# INTENTS DECOMP #############");
        println("Total functions: " + fm.getFunctionCount());
        for (String needle : TARGETS) {
            int matches = 0;
            for (Function f : fm.getFunctions(true)) {
                if (!f.getName(true).contains(needle)) continue;
                long entry = f.getEntryPoint().getOffset();
                if (seen.contains(entry)) continue;
                seen.add(entry);
                matches++;
                println("============================================================");
                println("FUNCTION: " + f.getName(true));
                println("Entry:    0x" + Long.toHexString(entry));
                println("Size:     " + f.getBody().getNumAddresses() + " bytes");
                println("------------------------------------------------------------");
                DecompileResults res = ifc.decompileFunction(f, 180, monitor);
                if (res != null && res.decompileCompleted()) {
                    println(res.getDecompiledFunction().getC());
                    total++;
                } else {
                    println("[failed]");
                }
                println("");
            }
            if (matches == 0) println(">>> NOT FOUND: " + needle);
        }
        println("############# DONE #############  total=" + total);
    }
}
