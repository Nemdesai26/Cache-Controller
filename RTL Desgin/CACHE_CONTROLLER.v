`timescale 1ns / 1ps
`include "cache_pkg.vh"
//////////////////////////////////////////////////////////////////////////////

// Policy:
//   - L1: direct-mapped, write-back with dirty bit
//   - L2: 4-way set-associative, pseudo-LRU replacement, write-back with
//         per-way dirty bit
//   - Writes are write-no-allocate on a miss: a write only ever updates a
//     line already resident in L1 or L2; a full write-miss goes straight
//     to main memory without installing a new line.
//   - Reads allocate on every level as they travel down: an L2 hit is
//     promoted into L1; a main-memory fetch is installed into both L2
//     and L1.
//   - Evictions only write back if the victim's dirty bit is set; clean
//     victims are simply dropped.
//////////////////////////////////////////////////////////////////////////////
module cache_controller (
    input  wire                    clk,
    input  wire                    rst,

    input  wire                    req_valid,
    output wire                    req_ready,
    input  wire [`WORD_WIDTH-1:0]  req_addr,
    input  wire [`WORD_WIDTH-1:0]  req_wdata,
    input  wire [3:0]              req_wstrb,   // 4'b0000 = read

    output reg                     resp_valid,
    output reg  [`WORD_WIDTH-1:0]  resp_rdata,
    output reg                     hit1,        // resolved in L1
    output reg                     hit2         // resolved in L2 (L1 miss)
);

    // ------------------------------------------------------------------
    // state encoding
    // ------------------------------------------------------------------
    localparam S_IDLE        = 4'd0,
               S_L1_LOOKUP   = 4'd1,
               S_L2_WAIT     = 4'd2,
               S_L2_LOOKUP   = 4'd3,
               S_MM_WAIT     = 4'd4,
               S_MM_ACCESS   = 4'd5,
               S_MM_DATA     = 4'd6,
               S_L2_EVICT    = 4'd7,
               S_L2_FILL     = 4'd8,
               S_L1_EVICT_WB = 4'd9,
               S_L1_FILL     = 4'd10,
               S_MM_WRITE    = 4'd11,
               S_DONE        = 4'd12;

    reg [3:0] state, next_state;

    // ------------------------------------------------------------------
    // latched request + working registers (pure data, no control timing
    // subtleties - just captured when the relevant state is current)
    // ------------------------------------------------------------------
    reg [`WORD_WIDTH-1:0] req_addr_r;
    reg [`WORD_WIDTH-1:0] wdata_r;
    reg [3:0]              wstrb_r;
    reg                    is_write_r;

    reg [3:0]              delay_cnt;

    reg [`WORD_WIDTH-1:0]  mm_rdata_r;
    reg [`L2_WAY_BITS-1:0] l2_victim_way_r;
    reg [`L2_TAG_BITS-1:0] l2_evict_tag_r;
    reg [`WORD_WIDTH-1:0]  l2_evict_data_r;

    reg [`L1_TAG_BITS-1:0] l1_evict_tag_r;
    reg [`WORD_WIDTH-1:0]  l1_evict_data_r;

    reg [`WORD_WIDTH-1:0]  l1_fill_data_r;

    // ------------------------------------------------------------------
    // address decode (stable for the whole transaction once latched)
    // ------------------------------------------------------------------
    wire [`BLK_ID_BITS-1:0]   blk_id   = req_addr_r[`BLK_ID_BITS+1:2];
    wire [`L1_INDEX_BITS-1:0] l1_index = blk_id[`L1_INDEX_BITS-1:0];
    wire [`L1_TAG_BITS-1:0]   l1_tag   = blk_id[`BLK_ID_BITS-1:`L1_INDEX_BITS];
    wire [`L2_INDEX_BITS-1:0] l2_index = blk_id[`L2_INDEX_BITS-1:0];
    wire [`L2_TAG_BITS-1:0]   l2_tag   = blk_id[`BLK_ID_BITS-1:`L2_INDEX_BITS];

    // reconstructed set/tag in L2 (and address in MM) for a block being
    // evicted out of L1 - see cache_pkg.vh for the derivation
    wire [`L2_INDEX_BITS-1:0] l1_evict_l2_index = {l1_evict_tag_r[`L1_TAG_BITS-`L2_TAG_BITS-1:0], l1_index};
    wire [`L2_TAG_BITS-1:0]   l1_evict_l2_tag   = l1_evict_tag_r[`L1_TAG_BITS-1:`L1_TAG_BITS-`L2_TAG_BITS];
    wire [`BLK_ID_BITS-1:0]   l1_evict_mm_addr  = {l1_evict_tag_r, l1_index};

    wire [`BLK_ID_BITS-1:0]   l2_evict_mm_addr  = {l2_evict_tag_r, l2_index};

    // ------------------------------------------------------------------
    // l1_cache instance - index fixed to l1_index for the whole
    // transaction; read is always live, only one write path pulses at a time
    // ------------------------------------------------------------------
    wire [`WORD_WIDTH-1:0]  l1_rdata;
    wire [`L1_TAG_BITS-1:0] l1_rtag;
    wire                    l1_rvalid, l1_rdirty;

    reg l1_we_data, l1_we_line;
    reg [`WORD_WIDTH-1:0] l1_line_wdata;

    l1_cache u_l1 (
        .clk(clk), .rst(rst),
        .index(l1_index),
        .rdata(l1_rdata), .rtag(l1_rtag), .rvalid(l1_rvalid), .rdirty(l1_rdirty),
        .we_data(l1_we_data), .wstrb(wstrb_r), .wdata(wdata_r),
        .we_line(l1_we_line), .wtag(l1_tag), .line_wdata(l1_line_wdata), .line_dirty_in(1'b0)
    );

    // ------------------------------------------------------------------
    // l2_cache instance - index/tag/data/wstrb are all muxed together by
    // the SAME combinational selector (l2_use_l1evict), so a write and
    // the index it targets can never drift apart by a clock cycle
    // ------------------------------------------------------------------
    reg l2_use_l1evict;   // 1 while this cycle's L2 access is the L1-eviction search/writeback, not the main request

    wire [`L2_INDEX_BITS-1:0] l2_addr_mux  = l2_use_l1evict ? l1_evict_l2_index : l2_index;
    wire [`L2_TAG_BITS-1:0]   l2_wtag_mux  = l2_use_l1evict ? l1_evict_l2_tag   : l2_tag;
    wire [3:0]                l2_wstrb_mux = l2_use_l1evict ? 4'b1111           : wstrb_r;
    wire [`WORD_WIDTH-1:0]    l2_wdata_mux = l2_use_l1evict ? l1_evict_data_r   : wdata_r;

    wire [`L2_WAYS*`WORD_WIDTH-1:0]  l2_rdata_all;
    wire [`L2_WAYS*`L2_TAG_BITS-1:0] l2_rtag_all;
    wire [`L2_WAYS-1:0]              l2_rvalid_all;
    wire [`L2_WAYS-1:0]              l2_rdirty_all;
    wire [`L2_WAYS*2-1:0]            l2_rlru_all;

    reg [`L2_WAY_BITS-1:0] l2_wway;
    reg l2_we_data, l2_we_line, l2_we_lru;
    reg [`WORD_WIDTH-1:0] l2_line_wdata;
    reg [`L2_WAYS*2-1:0] l2_wlru_all;

    l2_cache u_l2 (
        .clk(clk), .rst(rst),
        .index(l2_addr_mux),
        .rdata_all(l2_rdata_all), .rtag_all(l2_rtag_all),
        .rvalid_all(l2_rvalid_all), .rdirty_all(l2_rdirty_all), .rlru_all(l2_rlru_all),
        .wway(l2_wway),
        .we_data(l2_we_data), .wstrb(l2_wstrb_mux), .wdata(l2_wdata_mux),
        .we_line(l2_we_line), .wtag(l2_wtag_mux),
        .line_wdata(l2_line_wdata), .line_dirty_in(1'b0),
        .we_lru(l2_we_lru), .wlru_all(l2_wlru_all)
    );

    // per-way slice helpers (indexed part-select, variable base - standard,
    // synthesizable pattern for muxing a flattened bus by a runtime index)
    function [`L2_TAG_BITS-1:0] l2_tag_of;
        input [1:0] way;
        input [`L2_WAYS*`L2_TAG_BITS-1:0] bus;
        l2_tag_of = bus[(way+1)*`L2_TAG_BITS-1 -: `L2_TAG_BITS];
    endfunction

    function [`WORD_WIDTH-1:0] l2_data_of;
        input [1:0] way;
        input [`L2_WAYS*`WORD_WIDTH-1:0] bus;
        l2_data_of = bus[(way+1)*`WORD_WIDTH-1 -: `WORD_WIDTH];
    endfunction

    function [1:0] l2_lru_of;
        input [1:0] way;
        input [`L2_WAYS*2-1:0] bus;
        l2_lru_of = bus[(way+1)*2-1 -: 2];
    endfunction

    // promote `hit_way` to MRU, decrementing every way whose LRU value
    // was strictly greater (standard pseudo-LRU stack update)
    function [`L2_WAYS*2-1:0] lru_promote;
        input [`L2_WAYS*2-1:0] cur;
        input [1:0] hit_way;
        reg [1:0] v [0:3];
        reg [1:0] hit_val;
        integer k;
        begin
            for (k = 0; k < 4; k = k + 1) v[k] = cur[(k+1)*2-1 -: 2];
            hit_val = v[hit_way];
            for (k = 0; k < 4; k = k + 1) begin
                if (k[1:0] == hit_way) v[k] = 2'd3;
                else if (v[k] > hit_val) v[k] = v[k] - 2'd1;
            end
            lru_promote = {v[3], v[2], v[1], v[0]};
        end
    endfunction

    // ------------------------------------------------------------------
    // main_memory instance
    // ------------------------------------------------------------------
    reg  [`BLK_ID_BITS-1:0] mm_addr;
    reg                     mm_re, mm_we;
    reg  [`WORD_WIDTH-1:0]  mm_wdata_mux;
    wire [`WORD_WIDTH-1:0]  mm_rdata;

    main_memory u_mm (
        .clk(clk), .rst(rst),
        .addr(mm_addr), .re(mm_re), .rdata(mm_rdata),
        .we(mm_we), .wdata(mm_wdata_mux)
    );

    // ------------------------------------------------------------------
    // combinational L2 hit / victim / L1-evict search helpers
    // ------------------------------------------------------------------
    reg l2_hit_c;
    reg [1:0] l2_hit_way_c;
    integer hw;
    always @(*) begin
        l2_hit_c = 1'b0;
        l2_hit_way_c = 2'd0;
        for (hw = 0; hw < 4; hw = hw + 1)
            if (l2_rvalid_all[hw] && (l2_tag_of(hw[1:0], l2_rtag_all) == l2_tag)) begin
                l2_hit_c = 1'b1;
                l2_hit_way_c = hw[1:0];
            end
    end

    reg [1:0] l2_victim_c;
    integer vw;
    always @(*) begin
        l2_victim_c = 2'd0;
        for (vw = 0; vw < 4; vw = vw + 1)
            if (l2_lru_of(vw[1:0], l2_rlru_all) == 2'd0)
                l2_victim_c = vw[1:0];
    end

    // valid only while l2_use_l1evict is asserted (S_L1_EVICT_WB)
    reg l1_evict_found_c;
    reg [1:0] l1_evict_way_c;
    integer ew;
    always @(*) begin
        l1_evict_found_c = 1'b0;
        l1_evict_way_c = 2'd0;
        for (ew = 0; ew < 4; ew = ew + 1)
            if (l2_rvalid_all[ew] && (l2_tag_of(ew[1:0], l2_rtag_all) == l1_evict_l2_tag)) begin
                l1_evict_found_c = 1'b1;
                l1_evict_way_c = ew[1:0];
            end
    end

    // does the current L1-install step (from an L2 hit-read, or an L2
    // fill after an MM fetch) need to evict a dirty L1 line first?
    wire l1_installing_from_l2hit = (state == S_L2_LOOKUP) && l2_hit_c && !is_write_r;
    wire l1_installing_from_fill  = (state == S_L2_FILL);
    wire l1_evict_trigger_c       = (l1_installing_from_l2hit || l1_installing_from_fill) && l1_rvalid && l1_rdirty;

    assign req_ready = (state == S_IDLE);

    // ------------------------------------------------------------------
    // combinational next-state + output logic
    // ------------------------------------------------------------------
    reg resp_valid_c;
    reg [`WORD_WIDTH-1:0] resp_rdata_c;
    reg hit1_c, hit2_c;

    always @(*) begin
        // defaults
        next_state    = state;
        l1_we_data    = 1'b0;
        l1_we_line    = 1'b0;
        l1_line_wdata = l1_fill_data_r;
        l2_we_data    = 1'b0;
        l2_we_line    = 1'b0;
        l2_we_lru     = 1'b0;
        l2_wway       = 2'd0;
        l2_line_wdata = mm_rdata_r;
        l2_wlru_all   = l2_rlru_all;
        l2_use_l1evict = 1'b0;
        mm_re         = 1'b0;
        mm_we         = 1'b0;
        mm_addr       = blk_id;
        mm_wdata_mux  = wdata_r;
        resp_valid_c  = 1'b0;
        resp_rdata_c  = resp_rdata;
        hit1_c        = hit1;
        hit2_c        = hit2;

        case (state)
        // ----------------------------------------------------------------
        S_IDLE: begin
            if (req_valid)
                next_state = S_L1_LOOKUP;
        end

        // L1 lookup result is available combinationally: index has been
        // l1_index since the request was latched, so it's ready now.
        S_L1_LOOKUP: begin
            if (l1_rvalid && (l1_rtag == l1_tag)) begin
                hit1_c = 1'b1;
                hit2_c = 1'b0;
                if (is_write_r) begin
                    l1_we_data   = 1'b1;
                    resp_rdata_c = 32'd0;
                end else begin
                    resp_rdata_c = l1_rdata;
                end
                next_state = S_DONE;
            end else begin
                hit1_c     = 1'b0;
                next_state = S_L2_WAIT;
            end
        end

        S_L2_WAIT: begin
            if (delay_cnt == `L2_LATENCY - 1)
                next_state = S_L2_LOOKUP;
        end

        S_L2_LOOKUP: begin
            if (l2_hit_c) begin
                hit2_c      = 1'b1;
                l2_wway     = l2_hit_way_c;
                l2_we_lru   = 1'b1;
                l2_wlru_all = lru_promote(l2_rlru_all, l2_hit_way_c);

                if (is_write_r) begin
                    l2_we_data   = 1'b1;
                    resp_rdata_c = 32'd0;
                    next_state   = S_DONE;
                end else begin
                    resp_rdata_c = l2_data_of(l2_hit_way_c, l2_rdata_all);
                    next_state   = l1_evict_trigger_c ? S_L1_EVICT_WB : S_L1_FILL;
                end
            end else begin
                hit2_c     = 1'b0;
                next_state = S_MM_WAIT;
            end
        end

        S_MM_WAIT: begin
            if (delay_cnt == `MM_LATENCY - 1) begin
                mm_addr = blk_id;
                if (is_write_r) begin
                    mm_we        = 1'b1;
                    mm_wdata_mux = wdata_r;
                    next_state   = S_MM_WRITE;
                end else begin
                    mm_re      = 1'b1;
                    next_state = S_MM_ACCESS;
                end
            end
        end

        S_MM_WRITE: begin
            resp_rdata_c = 32'd0;
            next_state   = S_DONE;
        end

        // main_memory read is synchronous - data lands the cycle after re
        S_MM_ACCESS: begin
            next_state = S_MM_DATA;
        end

        S_MM_DATA: begin
            if (l2_rvalid_all[l2_victim_c] && l2_rdirty_all[l2_victim_c])
                next_state = S_L2_EVICT;
            else
                next_state = S_L2_FILL;
        end

        S_L2_EVICT: begin
            mm_addr      = l2_evict_mm_addr;
            mm_we        = 1'b1;
            mm_wdata_mux = l2_evict_data_r;
            next_state   = S_L2_FILL;
        end

        S_L2_FILL: begin
            l2_wway       = l2_victim_way_r;
            l2_we_line    = 1'b1;
            l2_line_wdata = mm_rdata_r;
            l2_we_lru     = 1'b1;
            l2_wlru_all   = lru_promote(l2_rlru_all, l2_victim_way_r);

            resp_rdata_c = mm_rdata_r;
            next_state   = l1_evict_trigger_c ? S_L1_EVICT_WB : S_L1_FILL;
        end

        // l2_use_l1evict redirects the L2 port to the reconstructed evict
        // set/tag THIS cycle, for both the search and the writeback - no
        // register-timing mismatch, everything here is comb-this-cycle
        S_L1_EVICT_WB: begin
            l2_use_l1evict = 1'b1;
            if (l1_evict_found_c) begin
                l2_wway    = l1_evict_way_c;
                l2_we_data = 1'b1;
            end else begin
                mm_addr      = l1_evict_mm_addr;
                mm_we        = 1'b1;
                mm_wdata_mux = l1_evict_data_r;
            end
            next_state = S_L1_FILL;
        end

        S_L1_FILL: begin
            l1_we_line    = 1'b1;
            l1_line_wdata = l1_fill_data_r;
            next_state    = S_DONE;
        end

        S_DONE: begin
            resp_valid_c = 1'b1;
            next_state   = S_IDLE;
        end

        default: next_state = S_IDLE;
        endcase
    end

    // ------------------------------------------------------------------
    // sequential: state + data-capture registers only
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state      <= S_IDLE;
            resp_valid <= 1'b0;
            resp_rdata <= {`WORD_WIDTH{1'b0}};
            hit1       <= 1'b0;
            hit2       <= 1'b0;
            delay_cnt  <= 4'd0;
        end else begin
            state      <= next_state;
            resp_valid <= resp_valid_c;
            resp_rdata <= resp_rdata_c;
            hit1       <= hit1_c;
            hit2       <= hit2_c;

            // latch the incoming request
            if (state == S_IDLE && req_valid) begin
                req_addr_r <= req_addr;
                wdata_r    <= req_wdata;
                wstrb_r    <= req_wstrb;
                is_write_r <= (req_wstrb != 4'b0000);
            end

            // delay counters: reset whenever leaving IDLE into a wait
            // stage, or when a wait stage's own count expires
            if ((state == S_L1_LOOKUP) || (state == S_L2_LOOKUP))
                delay_cnt <= 4'd0;
            else if (state == S_L2_WAIT)
                delay_cnt <= (delay_cnt == `L2_LATENCY - 1) ? 4'd0 : delay_cnt + 4'd1;
            else if (state == S_MM_WAIT)
                delay_cnt <= (delay_cnt == `MM_LATENCY - 1) ? 4'd0 : delay_cnt + 4'd1;

            // main-memory fetch + L2 victim/evict bookkeeping
            if (state == S_MM_DATA) begin
                mm_rdata_r      <= mm_rdata;
                l2_victim_way_r <= l2_victim_c;
                if (l2_rvalid_all[l2_victim_c] && l2_rdirty_all[l2_victim_c]) begin
                    l2_evict_tag_r  <= l2_tag_of(l2_victim_c, l2_rtag_all);
                    l2_evict_data_r <= l2_data_of(l2_victim_c, l2_rdata_all);
                end
            end

            // data to install into L1 once we reach S_L1_FILL
            if (l1_installing_from_l2hit)
                l1_fill_data_r <= l2_data_of(l2_hit_way_c, l2_rdata_all);
            else if (l1_installing_from_fill)
                l1_fill_data_r <= mm_rdata_r;

            // snapshot of the L1 line about to be evicted, taken before
            // it gets overwritten
            if (l1_evict_trigger_c) begin
                l1_evict_tag_r  <= l1_rtag;
                l1_evict_data_r <= l1_rdata;
            end
        end
    end

endmodule
