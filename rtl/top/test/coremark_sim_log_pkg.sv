// Host-side CoreMark diagnostics, separate from the decoded UART console.
`timescale 1ns/1ps
package coremark_sim_log_pkg;
    int sim_info_enabled = 1;
    int sim_color_enabled = 1;

    task automatic sim_log_init;
        if (!$value$plusargs("SIM_INFO=%d", sim_info_enabled)) sim_info_enabled = 1;
        if (!$value$plusargs("SIM_COLOR=%d", sim_color_enabled)) sim_color_enabled = 1;
    endtask

    task automatic sim_info(input string message);
        if (sim_info_enabled != 0)
            $display("%s%s%s", sim_color_enabled != 0 ? "\033[36m" : "", message,
                     sim_color_enabled != 0 ? "\033[0m" : "");
    endtask

    task automatic sim_success(input string message);
        if (sim_info_enabled != 0)
            $display("%s%s%s", sim_color_enabled != 0 ? "\033[32m" : "", message,
                     sim_color_enabled != 0 ? "\033[0m" : "");
    endtask

    // Quiet mode must not hide failing checks or timeout context.
    task automatic sim_error(input string message);
        $display("%s%s%s", sim_color_enabled != 0 ? "\033[31m" : "", message,
                 sim_color_enabled != 0 ? "\033[0m" : "");
    endtask
endpackage
