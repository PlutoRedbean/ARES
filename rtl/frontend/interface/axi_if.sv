interface axi_if #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned DATA_WIDTH = 32
);

    /*
    * AR Channel
    */
    logic [ADDR_WIDTH - 1:0] araddr;
    logic arvalid;
    logic arready;

    /*
    * R Channel
    */

    logic [DATA_WIDTH - 1:0] rdata;
    logic rresp;  // return err report
    logic rvalid;
    logic rready;

    /*
    * AW Channel
    */

    logic [ADDR_WIDTH - 1:0] awaddr;
    logic awvalid;
    logic awready;

    /*
    * W Channel
    */

    logic [DATA_WIDTH - 1:0] wdata;
    logic [7:0] wstrb;
    logic wvalid;
    logic wready;

    /*
    * B Channel
    */

    logic bresp;
    logic bvalid;
    logic bready;

    modport master(

        output araddr,
        output arvalid,
        input arready,

        input rdata,
        input rresp,
        input rvalid,
        output rready,

        output awaddr,
        output awvalid,
        input awready,

        output wdata,
        output wstrb,
        output wvalid,
        input wready,

        input bresp,
        input bvalid,
        output bready
    );

    modport slave(

        input araddr,
        input arvalid,
        output arready,

        output rdata,
        output rresp,
        output rvalid,
        input rready,

        input awaddr,
        input awvalid,
        output awready,

        input wdata,
        input wstrb,
        input wvalid,
        output wready,

        output bresp,
        output bvalid,
        input bready
    );

endinterface
