#include <gdf/gdf.h>
#include <gdf/ipc/Schema_generated.h>
#include <gdf/ipc/Message_generated.h>

#include <iostream>
#include <stdexcept>
#include <memory>
#include <vector>
#include <string>

using namespace org::apache::arrow;

class IpcParser {
public:

    typedef std::unique_ptr<const char []> unique_bytes_type;

    class ParseError : public std::runtime_error {
        using std::runtime_error::runtime_error;
    };

    struct MessageInfo {
        const void *header;
        int64_t body_length;
        flatbuf::MessageHeader type;
    };

    struct LayoutDesc {
        int bitwidth;
        std::string vectortype;
    };

    struct FieldDesc {
        std::string name;
        std::string type;
        std::vector<LayoutDesc> layouts;
    };

    struct BufferDesc {
        int64_t offset, length;

    };

    struct NodeDesc {
        std::string name;
        int64_t length;
        int64_t null_count;
        BufferDesc null_buffer, data_buffer;
        std::string type;
    };

    IpcParser(const char *buf)
    :_d_buffer(buf), _d_curptr(buf)
    { /* empty */ }

    void read() {
        if (_fields.size() || _nodes.size()) {
            throw ParseError("cannot call .read() more than once");
        }
        read_schema();
        read_record_batch();
    }

    void read_schema() {
        int size = read_msg_size();
        auto header_buf = read_bytes(size);
        auto header = parse_msg_header(header_buf);
        if ( header.body_length > 0) {
            throw ParseError("schema should not have a body");
        }
        parse_schema(header);
    }

    void read_record_batch() {
        int size = read_msg_size();
        auto header_buf = read_bytes(size);
        auto header = parse_msg_header(header_buf);
        if ( header.body_length <= 0) {
            throw ParseError("recordbatch should have a body");
        }
        // store the current ptr as the data ptr
        _d_data_body = _d_curptr;
        parse_record_batch(header);
    }

    MessageInfo parse_msg_header(const unique_bytes_type & header_buf) {
        auto msg = flatbuf::GetMessage(header_buf.get());
        MessageInfo mi;
        mi.header = msg->header();
        mi.body_length = msg->bodyLength();
        mi.type = msg->header_type();
        return mi;
    }

    void parse_schema(MessageInfo msg) {
        if ( msg.type != flatbuf::MessageHeader_Schema ) {
            throw ParseError("expecting schema type");
        }
        auto schema = static_cast<const flatbuf::Schema*>(msg.header);
        auto fields = schema->fields();

        _fields.reserve(fields->Length());
        for ( int i=0; i < fields->Length(); ++i ){
            auto field = fields->Get(i);

            _fields.push_back(FieldDesc());
            auto & out_field = _fields.back();

            out_field.name = field->name()->str();
            out_field.type = flatbuf::EnumNameType(field->type_type());

            auto layouts = field->layout();
            for ( int j=0; j < layouts->Length(); ++j ) {
                auto layout = layouts->Get(j);
                LayoutDesc layout_desc;
                layout_desc.bitwidth = layout->bit_width();
                layout_desc.vectortype = flatbuf::EnumNameVectorType(layout->type());
                out_field.layouts.push_back(layout_desc);
            }
        }
    }

    void parse_record_batch(MessageInfo msg) {
        if ( msg.type != flatbuf::MessageHeader_RecordBatch ) {
            throw ParseError("expecting recordbatch type");
        }

        auto rb = static_cast<const flatbuf::RecordBatch*>(msg.header);

        int node_ct = rb->nodes()->Length();
        int buffer_ct = rb->buffers()->Length();

        int buffer_per_node = 2;
        if ( node_ct * buffer_per_node != buffer_ct ) {
            throw ParseError("unexpected: more than 2 buffers per node!?");
        }

        _nodes.reserve(node_ct);
        for ( int i=0; i < node_ct; ++i ) {
            const auto &fd = _fields[i];
            auto node = rb->nodes()->Get(i);

            _nodes.push_back(NodeDesc());
            auto &out_node = _nodes.back();

            for ( int j=0; j < buffer_per_node; ++j ) {
                auto buf = rb->buffers()->Get(i * buffer_per_node + j);
                if ( buf->page() != -1 ) {
                    std::cerr << "buf.Page() != -1; metadata format changed!\n";
                }

                const auto &layout = fd.layouts[j];

                BufferDesc bufdesc;
                bufdesc.offset = buf->offset();
                bufdesc.length = buf->length();

                if ( layout.vectortype == "DATA" ) {
                    out_node.data_buffer = bufdesc;
                } else if ( layout.vectortype == "VALIDITY" ) {
                    out_node.null_buffer = bufdesc;
                } else {
                    throw ParseError("unsupported vector type");
                }
            }

            out_node.name = fd.name;
            out_node.length = node->length();
            out_node.null_count = node->null_count();
            out_node.type = fd.type;
        }
    }


protected:
    unique_bytes_type read_bytes(size_t size) {
        if (size <= 0) {
            throw ParseError("attempt to read zero or negative bytes");
        }
        char *buf = new char[size];
        if (cudaSuccess != cudaMemcpy(buf, _d_curptr,  size,
                                      cudaMemcpyDeviceToHost) )
            throw ParseError("cannot read value");
        _d_curptr += size;
        return unique_bytes_type(buf);
    }

    template<typename T>
    void read_value(T &val) {
        if (cudaSuccess != cudaMemcpy(&val, _d_curptr,  sizeof(T),
                                      cudaMemcpyDeviceToHost) )
            throw ParseError("cannot read value");
        _d_curptr += sizeof(T);
    }

    int read_msg_size() {
        int size;
        read_value(size);
        if (size <= 0) {
            throw ParseError("non-positive message size");
        }
        return size;
    }



private:
    const char * const _d_buffer;
    const char *_d_curptr;
    const char *_d_data_body;
    std::vector<FieldDesc> _fields;
    std::vector<NodeDesc> _nodes;

};


void gdf_ipc_parse(const char *device_bytes) {
    try {
        IpcParser parser(device_bytes);
        parser.read();
    } catch (IpcParser::ParseError e) {
        std::cerr << "IPC parser error:" << e.what() << std::endl;
    }
}
