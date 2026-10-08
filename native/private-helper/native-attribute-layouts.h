// Reviewed runtime metadata for the fixed generated public fixture only.
// Exact raw input SHA256: a5abc6b1588edb5cc70da3371e3d6cc71eb56506a7483b469c082f4c8486eb53.
// Metadata is a layout contract, not proof of semantic archive completeness.
#ifndef ANM_NATIVE_ATTRIBUTE_LAYOUTS_H
#define ANM_NATIVE_ATTRIBUTE_LAYOUTS_H
static NSDictionary *ANMObservedNativeLayout(NSString *name) {
  NSDictionary *layouts = @{
    @"ICTTAttachment" : @{
      @"superclass" : @"NSObject",
      @"instanceSize" : @24,
      @"ivars" : @{
        @"_attachmentIdentifier" : @{
          @"encoding" : @"@\"NSString\"",
          @"offset" : @8
        },
        @"_attachmentUTI" : @{
          @"encoding" : @"@\"NSString\"",
          @"offset" : @16
        }
      },
      @"properties" : @{
        @"attachmentIdentifier" : @{
          @"attributes" : @"T@\"NSString\",C,N,V_attachmentIdentifier",
          @"returnType" : @"@",
          @"selector" : @"attachmentIdentifier"
        },
        @"attachmentUTI" : @{
          @"attributes" : @"T@\"NSString\",C,N,V_attachmentUTI",
          @"returnType" : @"@",
          @"selector" : @"attachmentUTI"
        },
        @"debugDescription" : @{
          @"attributes" : @"T@\"NSString\",?,R,C",
          @"returnType" : @"@",
          @"selector" : @"debugDescription"
        },
        @"description" : @{
          @"attributes" : @"T@\"NSString\",R,C",
          @"returnType" : @"@",
          @"selector" : @"description"
        },
        @"hash" : @{
          @"attributes" : @"TQ,R",
          @"returnType" : @"Q",
          @"selector" : @"hash"
        },
        @"superclass" : @{
          @"attributes" : @"T#,R",
          @"returnType" : @"#",
          @"selector" : @"superclass"
        }
      }
    },
    @"ICTTFont" : @{
      @"superclass" : @"NSObject",
      @"instanceSize" : @40,
      @"ivars" : @{
        @"_fontHints" : @{
          @"encoding" : @"I",
          @"offset" : @8
        },
        @"_fontName" : @{
          @"encoding" : @"@\"NSString\"",
          @"offset" : @16
        },
        @"_nativeFont" : @{
          @"encoding" : @"@",
          @"offset" : @32
        },
        @"_pointSize" : @{
          @"encoding" : @"d",
          @"offset" : @24
        }
      },
      @"properties" : @{
        @"fontHints" : @{
          @"attributes" : @"TI,R,N,V_fontHints",
          @"returnType" : @"I",
          @"selector" : @"fontHints"
        },
        @"fontName" : @{
          @"attributes" : @"T@\"NSString\",R,N,V_fontName",
          @"returnType" : @"@",
          @"selector" : @"fontName"
        },
        @"nativeFont" : @{
          @"attributes" : @"T@,&,N,V_nativeFont",
          @"returnType" : @"@",
          @"selector" : @"nativeFont"
        },
        @"pointSize" : @{
          @"attributes" : @"Td,R,N,V_pointSize",
          @"returnType" : @"d",
          @"selector" : @"pointSize"
        }
      }
    },
    @"ICTTMutableParagraphStyle" : @{
      @"superclass" : @"ICTTParagraphStyle",
      @"instanceSize" : @80,
      @"ivars" : @{},
      @"properties" : @{
        @"alignment" : @{
          @"attributes" : @"Tq,D,N",
          @"returnType" : @"q",
          @"selector" : @"alignment"
        },
        @"blockQuoteLevel" : @{
          @"attributes" : @"TQ,D,N",
          @"returnType" : @"Q",
          @"selector" : @"blockQuoteLevel"
        },
        @"hints" : @{
          @"attributes" : @"TI,D,N",
          @"returnType" : @"I",
          @"selector" : @"hints"
        },
        @"indent" : @{
          @"attributes" : @"TQ,D,N",
          @"returnType" : @"Q",
          @"selector" : @"indent"
        },
        @"needsListCleanup" : @{
          @"attributes" : @"TB,D,N",
          @"returnType" : @"B",
          @"selector" : @"needsListCleanup"
        },
        @"needsParagraphCleanup" : @{
          @"attributes" : @"TB,D,N",
          @"returnType" : @"B",
          @"selector" : @"needsParagraphCleanup"
        },
        @"startingItemNumber" : @{
          @"attributes" : @"TQ,D,N",
          @"returnType" : @"Q",
          @"selector" : @"startingItemNumber"
        },
        @"style" : @{
          @"attributes" : @"TI,D,N",
          @"returnType" : @"I",
          @"selector" : @"style"
        },
        @"todo" : @{
          @"attributes" : @"T@\"ICTTTodo\",&,D,N",
          @"returnType" : @"@",
          @"selector" : @"todo"
        },
        @"uuid" : @{
          @"attributes" : @"T@\"NSUUID\",C,D,N",
          @"returnType" : @"@",
          @"selector" : @"uuid"
        },
        @"writingDirection" : @{
          @"attributes" : @"Tq,D,N",
          @"returnType" : @"q",
          @"selector" : @"writingDirection"
        }
      }
    },
    @"ICTTParagraphStyle" : @{
      @"superclass" : @"NSObject",
      @"instanceSize" : @80,
      @"ivars" : @{
        @"_alignment" : @{
          @"encoding" : @"q",
          @"offset" : @24
        },
        @"_blockQuoteLevel" : @{
          @"encoding" : @"Q",
          @"offset" : @48
        },
        @"_hints" : @{
          @"encoding" : @"I",
          @"offset" : @16
        },
        @"_indent" : @{
          @"encoding" : @"Q",
          @"offset" : @40
        },
        @"_needsListCleanup" : @{
          @"encoding" : @"B",
          @"offset" : @9
        },
        @"_needsParagraphCleanup" : @{
          @"encoding" : @"B",
          @"offset" : @8
        },
        @"_startingItemNumber" : @{
          @"encoding" : @"Q",
          @"offset" : @56
        },
        @"_style" : @{
          @"encoding" : @"I",
          @"offset" : @12
        },
        @"_todo" : @{
          @"encoding" : @"@\"ICTTTodo\"",
          @"offset" : @64
        },
        @"_uuid" : @{
          @"encoding" : @"@\"NSUUID\"",
          @"offset" : @72
        },
        @"_writingDirection" : @{
          @"encoding" : @"q",
          @"offset" : @32
        }
      },
      @"properties" : @{
        @"alignment" : @{
          @"attributes" : @"Tq,N,V_alignment",
          @"returnType" : @"q",
          @"selector" : @"alignment"
        },
        @"blockQuoteLevel" : @{
          @"attributes" : @"TQ,N,V_blockQuoteLevel",
          @"returnType" : @"Q",
          @"selector" : @"blockQuoteLevel"
        },
        @"canIndent" : @{
          @"attributes" : @"TB,R,N",
          @"returnType" : @"B",
          @"selector" : @"canIndent"
        },
        @"debugDescription" : @{
          @"attributes" : @"T@\"NSString\",?,R,C",
          @"returnType" : @"@",
          @"selector" : @"debugDescription"
        },
        @"description" : @{
          @"attributes" : @"T@\"NSString\",R,C",
          @"returnType" : @"@",
          @"selector" : @"description"
        },
        @"hash" : @{
          @"attributes" : @"TQ,R",
          @"returnType" : @"Q",
          @"selector" : @"hash"
        },
        @"hints" : @{
          @"attributes" : @"TI,N,V_hints",
          @"returnType" : @"I",
          @"selector" : @"hints"
        },
        @"indent" : @{
          @"attributes" : @"TQ,N,V_indent",
          @"returnType" : @"Q",
          @"selector" : @"indent"
        },
        @"isBlockQuote" : @{
          @"attributes" : @"TB,R,N",
          @"returnType" : @"B",
          @"selector" : @"isBlockQuote"
        },
        @"isChecklist" : @{
          @"attributes" : @"TB,R,N",
          @"returnType" : @"B",
          @"selector" : @"isChecklist"
        },
        @"isHeader" : @{
          @"attributes" : @"TB,R,N",
          @"returnType" : @"B",
          @"selector" : @"isHeader"
        },
        @"isList" : @{
          @"attributes" : @"TB,R,N",
          @"returnType" : @"B",
          @"selector" : @"isList"
        },
        @"isRTL" : @{
          @"attributes" : @"TB,R,N",
          @"returnType" : @"B",
          @"selector" : @"isRTL"
        },
        @"needsListCleanup" : @{
          @"attributes" : @"TB,N,V_needsListCleanup",
          @"returnType" : @"B",
          @"selector" : @"needsListCleanup"
        },
        @"needsParagraphCleanup" : @{
          @"attributes" : @"TB,N,V_needsParagraphCleanup",
          @"returnType" : @"B",
          @"selector" : @"needsParagraphCleanup"
        },
        @"preferSingleLine" : @{
          @"attributes" : @"TB,R,N",
          @"returnType" : @"B",
          @"selector" : @"preferSingleLine"
        },
        @"startingItemNumber" : @{
          @"attributes" : @"TQ,N,V_startingItemNumber",
          @"returnType" : @"Q",
          @"selector" : @"startingItemNumber"
        },
        @"style" : @{
          @"attributes" : @"TI,N,V_style",
          @"returnType" : @"I",
          @"selector" : @"style"
        },
        @"superclass" : @{
          @"attributes" : @"T#,R",
          @"returnType" : @"#",
          @"selector" : @"superclass"
        },
        @"supportsSectionLinks" : @{
          @"attributes" : @"TB,R,N",
          @"returnType" : @"B",
          @"selector" : @"supportsSectionLinks"
        },
        @"todo" : @{
          @"attributes" : @"T@\"ICTTTodo\",&,N,V_todo",
          @"returnType" : @"@",
          @"selector" : @"todo"
        },
        @"todoTrackingUUID" : @{
          @"attributes" : @"T@\"NSUUID\",R,N",
          @"returnType" : @"@",
          @"selector" : @"todoTrackingUUID"
        },
        @"uniqueToLine" : @{
          @"attributes" : @"TB,R,N",
          @"returnType" : @"B",
          @"selector" : @"uniqueToLine"
        },
        @"uuid" : @{
          @"attributes" : @"T@\"NSUUID\",C,N,V_uuid",
          @"returnType" : @"@",
          @"selector" : @"uuid"
        },
        @"wantsFollowingNewLine" : @{
          @"attributes" : @"TB,R,N",
          @"returnType" : @"B",
          @"selector" : @"wantsFollowingNewLine"
        },
        @"writingDirection" : @{
          @"attributes" : @"Tq,N,V_writingDirection",
          @"returnType" : @"q",
          @"selector" : @"writingDirection"
        }
      }
    },
    @"ICTTTodo" : @{
      @"superclass" : @"NSObject",
      @"instanceSize" : @24,
      @"ivars" : @{
        @"_done" : @{
          @"encoding" : @"B",
          @"offset" : @8
        },
        @"_uuid" : @{
          @"encoding" : @"@\"NSUUID\"",
          @"offset" : @16
        }
      },
      @"properties" : @{
        @"done" : @{
          @"attributes" : @"TB,R,N,V_done",
          @"returnType" : @"B",
          @"selector" : @"done"
        },
        @"uuid" : @{
          @"attributes" : @"T@\"NSUUID\",R,N,V_uuid",
          @"returnType" : @"@",
          @"selector" : @"uuid"
        }
      }
    }
  };
  return layouts[name];
}
#endif
