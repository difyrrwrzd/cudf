# automatically generated by the FlatBuffers compiler, do not modify

# namespace: flatbuf

import flatbuffers

class Binary(object):
    __slots__ = ['_tab']

    @classmethod
    def GetRootAsBinary(cls, buf, offset):
        n = flatbuffers.encode.Get(flatbuffers.packer.uoffset, buf, offset)
        x = Binary()
        x.Init(buf, n + offset)
        return x

    # Binary
    def Init(self, buf, pos):
        self._tab = flatbuffers.table.Table(buf, pos)

def BinaryStart(builder): builder.StartObject(0)
def BinaryEnd(builder): return builder.EndObject()
