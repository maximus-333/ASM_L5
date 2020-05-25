.186

.stack 200h

;Lab 5, var 19 (for 7 and 8 - vars 4 and 9)
;Task - take file, delete all words that match provided word.
;Subtasks:
;-Parameters(including path) are passed through command line
;-Don't load entire file into buffer 
;-Word can have spaces and tabulation on both ends(cut that off). Max size is 50 symbols

;Notes:
;-Useful interrupts:
;  -21h/3Dh - open existing file
;  -21h/3Eh - close file
;  -21h/3Fh - read bytes from file
;  -21h/40h - write bytes to file
;  -21h/42h - SEEK
;  -To truncate - use write with 0 length
;-Console arguments - through PSP(from 80h to 100h). Maybe need to separate arguments or smth
;-Offsets of buffers(inp;outp): 0731:000A , 0741:000A ; 0752:000E



.data
   pspSegm dw ?   ;console args are located in this at offset 80h
   
   argsLen        db ?
   
   path           db db 129 DUP(0)        ;path string. Must be ASCIIZ, so fill with zeroes
   fileHandle     dw ?
   
   searchWordSize db 50                   ;length of string
   searchWordStr  db 51 DUP(0)            ;letters
   
   offsetIn       dw 2 DUP(0)
   ;endLength      dw 513
   bufferInLow    db 256 DUP(0)
   bufferInHigh   db 256 DUP(0)
   
   offsetOut      dw 2 DUP(0) 
   bufferOut      db 512 DUP(?)
   bufferOutEnd:  db 0 ;just a label to detect end of buffer

   infoArgsErr    db "Invalid arguments!", '$'
   infoOpenErr    db "Can't open file. Code:", '$'
   infoRWErr      db "Can't read/write to file. Code:", '$'
   
   

.code
;------------------------MACROS------------------------


;Transfer 32-bit file offset between registers and memory.
;Both macros are used with a SEEK interrupt to store the offset
loadOffset MACRO dwVar
   mov cx, WORD PTR dwVar[0]
   mov dx, WORD PTR dwVar[2]
ENDM   
storeOffset MACRO dwVar
   mov WORD PTR dwVar[0], dx    ;seek returns into different 
   mov WORD PTR dwVar[2], ax    ;pair of registers for some reason
ENDM


;-------------------------CODE-------------------------


start:
   push ds
   
   mov bx, @data
   mov ds, bx
   pop bx
   mov es, bx   
   mov pspSegm, bx
   

      ;(check AL for disk letter error?(0FFh if wrong, otherwise 00h))
   
   
   
   call readArgs
   cmp searchWordSize, 0
   jne noErrorArgs
      ;Couldn't load arguments   
      lea dx, infoArgsErr
      mov ah, 09h
      int 21h
      jmp main_finish
   noErrorArgs:
   
   ;Got the arguments. Now open file 
   mov ah, 3Dh
   mov al, 02h    ;mode - shared read/write
   mov dx, offset path
   int 21h
   jnc noOpenError
      ;Couldn't open file
      lea dx, infoOpenErr
      mov ah, 09h
      int 21h
      ;display error code
      mov dl, al
      add dl, '0'
      mov ah, 2
      int 21h
      
      jmp main_finish
   noOpenError:
   mov fileHandle, ax
   
   ;restore segments to usual
   mov si, ds
   mov es, si

   
   ;(test read/write)
   ;reading one byte
   mov bx, fileHandle
   mov dx, offset bufferInLow
   mov cx, 1
   mov ah, 3Fh
   int 21h
   jc fileIOError
   ;moving back to pos 0
   mov al, 0
   xor cx, cx
   xor dx, dx
   mov ah, 42h
   int 21h
   ;writing the same byte back    
   mov cx, 1
   mov dx, offset bufferInLow
   mov ah, 40h
   int 21h
   jc fileIOError
   jmp noFileIOError
   fileIOError:
      ;Coudn't read to file
      lea dx, infoRWErr
      mov ah, 09h
      int 21h
      jmp main_finish
   noFileIOError:
   

   
   
   
   ;Now, start the process
   lea si, bufferInLow
   lea di, bufferOut
   xor cx, cx
   ;load initial buffer
   CALL readHalf
   CALL copyToLow
   CALL readHalf
   
   CALL checkWord ;words can start right away
   mov ch, 0Fh    ;CH=0Fh is used as "prev char is space" flag
   mainLoop:
      cmp [si], 0
      je mainLoopEnd ;reached end of file. Leave
   
      ;find if need to check for word
      cmp [si], '0'
      jl startWordCmp
      cmp [si], '9'
      jle noWordCmp
      cmp [si], 'A'
      jl startWordCmp
      cmp [si], 'Z'
      jle noWordCmp
      cmp [si], 'a'
      jl startWordCmp
      cmp [si], 'z'
      jle noWordCmp


      startWordCmp:  ;start of next word, maybe it's the one
         mov cl, 0Fh   ;CL=0Fh is used as a "beginning of word" flag
      noWordCmp:     ;regular letter, not a part of word
      
      cmp si, offset bufferInHigh
      jle mainLoop_noShift ;don't need to load new data yet
         ;attach next part of file to array
         CALL copyToLow
         sub si, 256
         CALL readHalf
      mainLoop_noShift:
      
      
      cmp [si], ' '           ;Check if current char is space
      jne spaceRem_noSpace
         cmp ch, 0Fh          ;If multiple spaces in row, skip all except 1st. Means can skip all write-related code
         mov ch, 0Fh       ;curr char is space. Must set flag    
         je mainLoop_noFlush
         jmp spaceRem_noClear 
      spaceRem_noSpace:
      xor ch, ch  ;clear "prev char is space" flag
      spaceRem_noClear:
      ;move symbol into output buffer
      mov ah, [si]
      mov [di], ah      
      inc di
      cmp di, offset bufferOutEnd
      jne mainLoop_noFlush
      ;output buffer is full. Write it back to file, reset iterator
         CALL writeBuf
         lea di, bufferOut
      mainLoop_noFlush:
      inc si
      
      cmp cl, 0Fh       ;Check "beginning of word" flag. If true, 
      jne wordNoCmp     ;start compare routine from its first letter
         CALL checkWord
      wordNoCmp:
      mov cl, 02h  ;to keep loop going
   loop mainLoop
   mainLoopEnd:
   ;Processed all data, but still have some in output buffer. Write it to file
   CALL writeBuf
   ;Truncate file
   mov di, offset bufferOut   ;put di on beginning of its array
   CALL writeBuf  ;(writing zero bytes truncates file to current pos)
   
   
   main_finish:
   ;Close file
   mov bx, fileHandle
   mov ah, 3Eh
   int 21h
   
   ;idk, should be it.
   
   ;Return control to system.
   mov ah, 4Ch
   int 21h
   
   
   
;=====================================FUNCTIONS=====================================
















;Reads console arguments - path and word to search.
;On error, searchWordSize = 0
PROC readArgs
   pusha
   ;read length of args
   mov di, 80h
   mov al, es:[di]
   mov argsLen, al
   inc di
   
   ;search 1st parameter(path)
   mov cx, 128 ;max amount of skipped spaces
   mov al, ' '
   repe scasb  ;skip spaces
   dec di      ;to end up on 1st letter
   ;actual reading
   mov bx, offset path
   xor cx, cx  ;size unknown, no point in limiting    
   arg1Loop:   ;copy path to variable
      mov al, es:[di]
        
      cmp al, ' '
      je arg1LoopEnd
      cmp al, 009 ;tabulation
      je arg1LoopEnd
      
      cmp al, 0Dh ;end of args
      je argFail  ;don't have 2nd argument - that's an error
      
      mov [bx], al ;store char in path string
      inc di
      inc bx 
   loop arg1Loop
   arg1LoopEnd:
   
   ;Reading arg 2
   
   ;Skip initial spaces and tabs
   arg2PreLoop:
      mov al, es:[di]
      inc di
      
      cmp al, ' '
      je arg2PreLoop
      cmp al, 009 ;tab
      je arg2PreLoop
   dec di
   ;Found beginning of arg 2. Read it
   xor bx, bx
   xor cx, cx
   mov cl, searchWordSize  ;If cx runs out, word is too large - error
   inc cl
   arg2Loop:   
      mov al, es:[di]
      inc di
      
      cmp al, ' '
      je arg2LoopEnd
      cmp al, 009 ;tab
      je arg2LoopEnd
      
      cmp al, 0Dh ;end of args
      je arg2LoopEnd
      
      arg2LoopWrite:
         mov searchWordStr[bx], al
         inc bx
   loop arg2Loop
   arg2LoopEnd:
   cmp cx, 0
   je argFail
   mov searchWordSize, bl
   popa
   ret
   argFail: ;incorrect arguments
   mov searchWordSize, 0
   popa
   ret
ENDP readArgs


;Reads 256 bytes from file into top half of input buffer.
;Includes SEEK. On EOF, string gets capped off by NULL-symbol.
PROC readHalf
   pusha
   ;first, seek pos
   mov bx, fileHandle
   loadOffset offsetIn
   mov al, 0
   mov ah, 42h
   int 21h
   ;got pos, now read data
   xor dx, dx
   lea dx, bufferInHigh
   mov cx, 256
   mov ah, 3Fh
   int 21h
   cmp ax, cx
   je noEOF
      ;End of file. Put null-character as last symbol
      lea di, bufferInHigh
      add di, ax
      mov [di], 0
   noEOF:
   
   ;get and store new file offset
   mov al, 1
   xor cx, cx
   xor dx, dx
   mov ah, 42h
   int 21h
   storeOffset offsetIn ;update offset variable
   
   popa
   ret
ENDP readHalf



;Copies bufferInHigh into bufferInLow. That's it!
;(doesn't transfer pointer though, need to do that separately)
PROC copyToLow
   pusha
   mov si, offset bufferInHigh
   mov di, offset bufferInLow
   mov cx, 256
   rep movsb
   popa
   ret
ENDP copyToLow   



;Writes bytes from bufferOut to DI into file.
PROC writeBuf
   pusha
   push di
   ;seek pos
   mov bx, fileHandle
   loadOffset offsetOut ;(macro)
   mov al, 0
   mov ah, 42h
   int 21h
   ;write data
   mov dx, offset bufferOut
   pop cx   
   sub cx, dx ;length from DI
   mov ah, 40h
   int 21h
   
   ;get and store new file offset
   mov al, 1
   xor cx, cx
   xor dx, dx
   mov ah, 42h
   int 21h
   storeOffset offsetOut ;update offset variable
   
   popa
   ret
ENDP writeBuf


;Function to compare word with target word, and skip on match.
;Needs SI to point at first letter of suspect word.
;If word matched and has ' ' right after it, skips it.
PROC checkWord
   push cx
   push di
   push si
   mov di, offset searchWordStr
   xor cx, cx
   mov cl, searchWordSize
   repe cmpsb
   cmp cx, 0
   jne cw_fail
   ;Check if word ended right after that
   cmp [si], '0'
   jl cw_match
   cmp [si], '9'
   jle cw_fail
   cmp [si], 'A'
   jl cw_match
   cmp [si], 'Z'
   jle cw_fail
   cmp [si], 'a'
   jl cw_match
   cmp [si], 'z'
   jle cw_fail

   cw_match:
   pop di      ;don't restore si, but keep stack intact
   pop di
   pop cx
   ret
   cw_fail:
   pop si
   pop di
   pop cx
   ret
ENDP checkWord


end start