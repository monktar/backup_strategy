﻿USE [master]
GO
/****** Object:  StoredProcedure [dbo].[sp_DatabaseRestore]    Script Date: 1/30/2020 11:11:58 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF  EXISTS (SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[sp_DatabaseRestore]') AND type in (N'P', N'PC'))
DROP PROCEDURE [dbo].[sp_DatabaseRestore]
GO


Create PROCEDURE [dbo].[sp_DatabaseRestore]
--declare
      @Database NVARCHAR(4000),
	  @RestoreDatabaseName NVARCHAR(MAX)= NULL,
	  @BackupPath NVARCHAR(MAX), 
	  @FullRecovery nvarchar(max) = 'N', --apply the diff after fullbackup is restored
	  @DiffRecovery nvarchar(max) = 'N', --apply the diff after fullbackup is restored
	  @LogRecovery nvarchar(max) = 'N',  --apply log after last diff is applied
	  @MoveFiles NVARCHAR(MAX)= 'N',
	  @MoveDataDrive NVARCHAR(MAX)= NULL,
	  @MoveLogDrive NVARCHAR(MAX)= NULL,
	  @TestRestore NVARCHAR(MAX)= 'N', 
	  @RunCheckDB NVARCHAR(MAX)= 'N', 
	  @Execute nvarchar(max) = 'N',
	  @LogToTable NVARCHAR(MAX)= 'N',
	  @RestoreDateTime datetime,
	  @dayBefore INT  = 1, 
	  @FullBackup NVARCHAR(500)='',
	  @DiffBackup NVARCHAR(500)=''
AS
BEGIN
		-- inspire by http://ola.hallengren.com
		----Example run: 
			--EXEC dbo.sp_DatabaseRestore @Database='thinkHealth', @BackupPath='C:\DatabaseBackups\', @DiffRecovery='Y', @LogRecovery='Y', @FullRecovery ='Y',
		 -- 						     @Execute='N', @LogToTable='N', @RestoreDateTime='20191201' , @FullBackup = '', @DiffBackup = ''		 ---- 
		 --TO RESTORE DIFFERENTIAL BACKUP, PLEASE DELETE THE TAILLOG BACKUP IF THEY ARE NO LONGER NEED. EXTENSION IS tailLOG

     SET NOCOUNT ON;

	 --set @BackupPath='\\DEVELOPER16\Backups\'--'C:\Backups\'
         -- 1 - Variable declaration 
         DECLARE @cmd NVARCHAR(MAX);
         DECLARE @cmd2 NVARCHAR(500);
         DECLARE @fileList TABLE ( backupFile NVARCHAR(255) );
         DECLARE @fileListForRestore TABLE ( backupFile NVARCHAR(255), WhenDate DATETIME, BackType varchar(5) );
         DECLARE @StartFull NVARCHAR(500);
		 DECLARE @StartLog NVARCHAR(500);
         DECLARE @StartDIFF NVARCHAR(500);  
         DECLARE @firstLogBackup NVARCHAR(500);
         DECLARE @backupFile NVARCHAR(500), @lastFullBackup NVARCHAR(500), @lastDiffBackup NVARCHAR(500)
         DECLARE @MoveDataLocation AS NVARCHAR(500);
         DECLARE @MoveDataLocationName AS NVARCHAR(500);
         DECLARE @MoveLogLocation AS NVARCHAR(500);
         DECLARE @MoveLogLocationName AS NVARCHAR(500);
		 DECLARE @lastFullBackupDate DATETIME 
		 DECLARE @lastDiffBackupDate DATETIME 
		 DECLARE @FirstLogBackupDate DATETIME 
		 DECLARE @lastGood NVARCHAR(500);

	 SET @dayBefore = -1 * @dayBefore
	 IF @RestoreDateTime IS NULL OR @RestoreDateTime = '19000101'
		SET @RestoreDateTime = dateadd(day, @dayBefore,@RestoreDateTime)

	 SET @StartFull = @Database+ '_FULL'
	 SET @StartLog = @Database+ '_LOG'
 	 SET @StartDIFF = @Database+ '_DIF'


	 


         IF @RestoreDatabaseName IS NULL
                 SET @RestoreDatabaseName = @database;


         --Assume this is a restore from AG
         DECLARE @FullCopyPath AS NVARCHAR(500);
         DECLARE @TlogPath AS NVARCHAR(500);
         SET @FullCopyPath = @BackupPath --+'FULL_COPY_ONLY\';
         SET @TlogPath = @BackupPath --+'LOG\';


	    declare @ReturnCode INT

         -- 3 - get list of files 
         SET @cmd2 = @FullCopyPath;
         INSERT INTO @fileList (backupFile)
         EXEC @ReturnCode = master.sys.xp_cmdshell @cmd2; 

		--if we have an error lets try for a full
		IF @ReturnCode <> 0
		BEGIN
			SET @FullCopyPath = @BackupPath--+'FULL\';
			SET @cmd2 = 'DIR  '+@FullCopyPath;
				INSERT INTO @fileList (backupFile)
				EXEC @ReturnCode = master.sys.xp_cmdshell @cmd2; 
		END

		--IF  (@DiffRecovery='Y' OR @LogRecovery='Y') AND @NoRecovery='N' BEGIN
		-- PRINT '!!!PLEASE REVIEW @NoRecovery REGARDING THE VALUES OF @DiffRecovery OR @LogRecovery !!! ' 
		-- RETURN -1
		--END

        SET @ReturnCode = 1
		SET @lastGood = ''


		IF NOT EXISTS(SELECT 1 FROM @fileList WHERE backupFile LIKE '%.bak' AND REVERSE( LEFT(REVERSE(backupFile),CHARINDEX(' ',REVERSE(backupFile))-1 ) ) LIKE ''+@StartFull+'%' AND CONVERT(DATETIME,SUBSTRING(backupFile,1,20),101) >  @RestoreDateTime )
		BEGIN
			RAISERROR ('****NO FULL BACKUP FOUND*****', 16, 1 ) 
			RETURN -1
		END

		 --4 - Find all good full backup 
        IF @FullRecovery='Y' BEGIN
			 WHILE EXISTS(SELECT 1 FROM @fileList WHERE backupFile LIKE '%.bak' AND REVERSE( LEFT(REVERSE(backupFile),CHARINDEX(' ',REVERSE(backupFile))-1 ) ) LIKE ''+@StartFull+'%' AND CONVERT(DATETIME,SUBSTRING(backupFile,1,20),101) >  @RestoreDateTime  ) 
			 BEGIN
				 SELECT @lastFullBackup = REVERSE( LEFT(REVERSE(backupFile),CHARINDEX(' ',REVERSE(backupFile))-1 ) ) --borrowed from Kin Shah/Aaron's on dba.stackexchange.com
							, @lastFullBackupDate = CONVERT(DATETIME,SUBSTRING(backupFile,1,20),101), @lastGood= backupFile        
				 FROM @fileList
				 WHERE backupFile LIKE '%.bak' AND REVERSE( LEFT(REVERSE(backupFile),CHARINDEX(' ',REVERSE(backupFile))-1 ) ) LIKE ''+@StartFull+'%' and CONVERT(DATETIME,SUBSTRING(backupFile,1,20),101) > @RestoreDateTime
				  ORDER BY CONVERT(DATETIME,SUBSTRING(backupFile,1,20),101) DESC

				SET @cmd = 'RESTORE VERIFYONLY FROM DISK = '''+@FullCopyPath+@lastFullBackup + ' '' ';
				EXECUTE @ReturnCode = [dbo].[sp_CommandExecute] @Command = @cmd, @CommandType = 'VERIFYONLY ' , @Mode = 1, @DatabaseName = @database, 
									@LogToTable = @LogToTable, @Execute = @Execute;
				IF (@ReturnCode <> 0) BEGIN
					SET @lastFullBackup = ''; SET @lastFullBackupDate= ''
					SET @ReturnCode = 1
					DELETE @fileList WHERE backupFile = @lastGood --REMOVE THE BAD ONE AND MOVE TO NEXT
					PRINT 'Checking fails on ' + @lastFullBackup
				END
				ELSE BEGIN
					INSERT INTO @fileListForRestore SELECT @lastFullBackup, @lastFullBackupDate, 'FULL'
					DELETE @fileList WHERE backupFile = @lastGood -- REMOVE THE CURRENT TO NEXT
				END
			END
			-- determine the full backup
			IF LEN(@FullBackup)>0 
				SELECT @lastFullBackup = backupFile, @lastFullBackupDate = WhenDate FROM  @fileListForRestore WHERE backupFile = @FullBackup
			ELSE 
				SELECT TOP 1 @lastFullBackup = backupFile, @lastFullBackupDate = WhenDate FROM  @fileListForRestore WHERE BackType='FULL' ORDER BY WhenDate DESC
			--check the next full back
		END
		

        SET @ReturnCode = 1
		SET @lastGood = ''
		-- 4 - Find ALL valid diff backup 
        IF  @FullRecovery='Y' AND @DiffRecovery = 'Y'   BEGIN
		    WHILE EXISTS(SELECT 1 FROM @fileList WHERE backupFile LIKE '%.DIF' AND REVERSE( LEFT(REVERSE(backupFile),CHARINDEX(' ',REVERSE(backupFile))-1 ) ) LIKE ''+@StartDIFF+'%' AND CONVERT(DATETIME,SUBSTRING(backupFile,1,20),101) >  @lastFullBackupDate  ) BEGIN
				SELECT @lastDiffBackup = REVERSE( LEFT(REVERSE(backupFile),CHARINDEX(' ',REVERSE(backupFile))-1 ) ) --borrowed from Kin Shah/Aaron's on dba.stackexchange.com		
							, @lastDiffBackupDate = CONVERT(DATETIME,SUBSTRING(backupFile,1,20),101), @lastGood= backupFile
				FROM @fileList  
				WHERE backupFile LIKE '%.DIF' AND REVERSE( LEFT(REVERSE(backupFile),CHARINDEX(' ',REVERSE(backupFile))-1 ) ) LIKE ''+@StartDIFF+'%' AND CONVERT(DATETIME,SUBSTRING(backupFile,1,20),101) >  @lastFullBackupDate 
				ORDER BY CONVERT(DATETIME,SUBSTRING(backupFile,1,20),101) DESC
				IF  @lastDiffBackup IS NULL BEGIN
					PRINT '****NO DIFFERENTIAL BACKUP FOUND*****'
					RETURN -1
				END
				SET @cmd = 'RESTORE VERIFYONLY FROM DISK = '''+@FullCopyPath+@lastDiffBackup + ' '' '; 
				EXECUTE @ReturnCode = [dbo].[sp_CommandExecute] @Command = @cmd, @CommandType = 'VERIFYONLY ' , @Mode = 1, @DatabaseName = @database, 
									@LogToTable = @LogToTable, @Execute = @Execute;
				IF (@ReturnCode <> 0) BEGIN
					SET @lastDiffBackup = ''; SET @lastDiffBackupDate=''
					SET @ReturnCode = 1
					DELETE @fileList WHERE backupFile = @lastGood -- REMOVE THE CURRENT TO NEXT
					PRINT 'Checking fails on ' + @lastDiffBackup
				END
				ELSE BEGIN
					DELETE @fileList WHERE backupFile = @lastGood -- REMOVE THE CURRENT TO NEXTT
					INSERT INTO @fileListForRestore SELECT @lastDiffBackup, @lastDiffBackupDate, 'DIF'
				END
			END
			-- determine the diff backup to use
			IF LEN(@DiffBackup)>0 
				SELECT @lastDiffBackup = backupFile, @lastDiffBackupDate = WhenDate FROM  @fileListForRestore WHERE backupFile = @DiffBackup
			ELSE 
				SELECT TOP 1 @lastDiffBackup = backupFile, @lastDiffBackupDate = WhenDate FROM  @fileListForRestore WHERE BackType='DIF' ORDER BY WhenDate DESC
			--check the next diff back
		END

		---- 4 - Find FIRST LOG backup after the diffbackup
		--IF  @FullRecovery = 'Y' AND @LogRecovery = 'Y' BEGIN
		--	SELECT TOP 1 @firstLogBackup = REVERSE( LEFT(REVERSE(backupFile),CHARINDEX(' ',REVERSE(backupFile))-1 ) ) --borrowed from Kin Shah/Aaron's on dba.stackexchange.com		
		--				, @FirstLogBackupDate = CONVERT(DATETIME,SUBSTRING(backupFile,1,20),101)
		--	FROM @fileList  
		--	WHERE backupFile LIKE '%.TRN'  
		--			AND backupFile LIKE ''+@StartLog+'%' 
		--			AND CONVERT(DATETIME,SUBSTRING(backupFile,1,20),101) > CASE WHEN @lastDiffBackupDate IS NOT NULL THEN @lastDiffBackupDate ELSE @lastFullBackupDate END
		--	ORDER BY CONVERT(DATETIME,SUBSTRING(backupFile,1,20),101) ASC
		--END


        SET @ReturnCode = 1
		SET @lastGood = ''

		IF  @FullRecovery='Y' AND @LogRecovery = 'Y'   BEGIN
		    WHILE EXISTS(SELECT 1 FROM @fileList WHERE backupFile LIKE '%.TRN' AND REVERSE( LEFT(REVERSE(backupFile),CHARINDEX(' ',REVERSE(backupFile))-1 ) ) LIKE ''+@StartLog+'%' AND CONVERT(DATETIME,SUBSTRING(backupFile,1,20),101) >  CASE WHEN @lastDiffBackupDate IS NOT NULL THEN @lastDiffBackupDate ELSE @lastFullBackupDate END  ) BEGIN
				SELECT @firstLogBackup = REVERSE( LEFT(REVERSE(backupFile),CHARINDEX(' ',REVERSE(backupFile))-1 ) ) --borrowed from Kin Shah/Aaron's on dba.stackexchange.com		
							, @FirstLogBackupDate = CONVERT(DATETIME,SUBSTRING(backupFile,1,20),101), @lastGood= backupFile
				FROM @fileList  
				WHERE backupFile LIKE '%.TRN' AND REVERSE( LEFT(REVERSE(backupFile),CHARINDEX(' ',REVERSE(backupFile))-1 ) ) LIKE ''+@StartLog+'%' AND CONVERT(DATETIME,SUBSTRING(backupFile,1,20),101) >  CASE WHEN @lastDiffBackupDate IS NOT NULL THEN @lastDiffBackupDate ELSE @lastFullBackupDate END 
				ORDER BY CONVERT(DATETIME,SUBSTRING(backupFile,1,20),101) ASC
				IF  @firstLogBackup IS NULL BEGIN
					PRINT '****NO LOG BACKUP FOUND*****'
					RETURN -1
				END
				SET @cmd = 'RESTORE VERIFYONLY FROM DISK = '''+@FullCopyPath+@firstLogBackup + ' '' '; 
				EXECUTE @ReturnCode = [dbo].[sp_CommandExecute] @Command = @cmd, @CommandType = 'VERIFYONLY ' , @Mode = 1, @DatabaseName = @database, 
									@LogToTable = @LogToTable, @Execute = @Execute;
				IF (@ReturnCode <> 0) BEGIN
					SET @firstLogBackup = ''; SET @FirstLogBackupDate = ''
					SET @ReturnCode = 1
					DELETE @fileList WHERE backupFile = @lastGood -- REMOVE THE CURRENT TO NEXT
					PRINT 'Checking fails on ' + @firstLogBackup
				END
				ELSE BEGIN
					DELETE @fileList WHERE backupFile = @lastGood -- REMOVE THE CURRENT TO NEXTT
					INSERT INTO @fileListForRestore SELECT @firstLogBackup, @FirstLogBackupDate, 'LOG'
				END
			END
			-- determine the diff backup to use
			SELECT TOP 1 @firstLogBackup = backupFile, @FirstLogBackupDate = WhenDate FROM  @fileListForRestore WHERE BackType='LOG' ORDER BY WhenDate ASC

		END
			   
		-- the available usable backups
		SELECT backupFile, WhenDate, BackType FROM @fileListForRestore ORDER BY WhenDate

         DECLARE @FileListParameters TABLE
			(LogicalName NVARCHAR(128) NOT NULL, PhysicalName NVARCHAR(260) NOT NULL, Type CHAR(1) NOT NULL, FileGroupName NVARCHAR(120) NULL, 
			  Size NUMERIC(20, 0) NOT NULL, MaxSize NUMERIC(20, 0) NOT NULL, FileID BIGINT NULL, CreateLSN NUMERIC(25, 0) NULL, 
			  DropLSN NUMERIC(25, 0) NULL, UniqueID UNIQUEIDENTIFIER NULL, ReadOnlyLSN NUMERIC(25, 0) NULL, ReadWriteLSN NUMERIC(25, 0) NULL, 
			  BackupSizeInBytes BIGINT NULL, SourceBlockSize INT NULL, FileGroupID INT NULL, LogGroupGUID UNIQUEIDENTIFIER NULL, 
			  DifferentialBaseLSN NUMERIC(25, 0) NULL, DifferentialBaseGUID UNIQUEIDENTIFIER NULL, IsReadOnly BIT NULL, IsPresent BIT NULL, 
			  TDEThumbprint VARBINARY(32) NULL
			);

         

		
		--don't disconnect users if you are not executing
		IF @Execute='Y' BEGIN
			-- **********CLOSE ALL CONNECTIONS ON THE DATABASE  
			DECLARE @dbid INT, @KillStatement char(30), @SysProcId smallint
			--define the targeted database 
			SELECT @dbid = dbid FROM sys.sysdatabases WHERE name = @RestoreDatabaseName 
			IF EXISTS (SELECT spid FROM sys.sysprocesses WHERE dbid = @dbid)
			  BEGIN
				PRINT '*********CREATE WOULD FAIL -DROPPING ALL CONNECTIONS*********'
				PRINT '----These processes are blocking the restore from occurring----'
				SELECT spid, hostname, loginame, status, last_batch FROM sys.sysprocesses WHERE dbid = @dbid 
				--Kill any connections while you are on master
				DECLARE SysProc CURSOR LOCAL FORWARD_ONLY DYNAMIC READ_ONLY FOR
				SELECT spid FROM master.dbo.sysprocesses WHERE dbid = @dbid
				OPEN SysProc
				FETCH NEXT FROM SysProc INTO @SysProcId
				WHILE @@FETCH_STATUS = 0
				BEGIN
					SET @KillStatement = 'KILL ' + CAST(@SysProcId AS char(30))
					EXEC (@KillStatement)
					FETCH NEXT FROM SysProc INTO @SysProcId
				END
			END
		END

		--IF  @TaiLog = 'Y' BEGIN
			--tail log to avoid replace when restoring - extension tailLOG to avoid its use later when restore log file
			EXEC [sp_DatabaseBackup] @Databases=@RestoreDatabaseName, @Directory=@BackupPath,
						  @BackupType='LOG', @ChangeBackupType='Y', @Verify='Y', @Compress='Y', @CheckSum='Y', @NoRecovery='Y', @DirectoryStructure = NULL,
						  @FileName='{DatabaseName}_{BackupType}_{Year}{Month}{Day}_{Hour}{Minute}{Second}_{FileNumber}.{FileExtension}',
						  @FileExtensionFull='bak', @FileExtensionDiff='tailLOG', @FileExtensionLog='tailLOG', @Init='N', @LogToTable=@LogToTable,
						  @Execute=@Execute
		--END

   		DECLARE @MoveOption AS NVARCHAR(max)
		DECLARE @Paths as varchar(8000)
		SET @MoveOption = '';

		SET @cmd = 'RESTORE DATABASE ['+@RestoreDatabaseName+'] FROM DISK = '''+@FullCopyPath+@lastFullBackup+''' WITH FILE = 1 '; 

		IF @LogRecovery = 'Y' OR (@DiffRecovery = 'Y' AND @lastDiffBackupDate IS NOT NULL)
			SET @cmd = @cmd + ', NORECOVERY'
		
		--@MoveFiles Not tested yet
		IF @FullRecovery='Y' AND @MoveFiles = 'Y' AND @lastFullBackup IS NOT NULL  BEGIN    
				DECLARE @fullpath AS NVARCHAR(500);
				SET @fullpath = @FullCopyPath + @lastFullBackup;
				INSERT INTO @FileListParameters
				EXEC ('restore filelistonly from disk='''+@fullpath+'''');
				SELECT @Paths = COALESCE(@Paths + ',','') + ' Move ''' +  LogicalName + ''' TO ''' + @MoveDataDrive + Right(PhysicalName, charindex('\', reverse(PhysicalName))-1) +''''
				FROM @FileListParameters
				SET @MoveOption = @Paths;
				SET @cmd = @cmd + @MoveOption+CHAR(13);
		END
         
		-- restore last full backup  
		IF  @FullRecovery='Y'
         EXECUTE @cmd = [dbo].[sp_CommandExecute]
                 @Command = @cmd, @CommandType = 'RESTORE DATABASE', @Mode = 1, @DatabaseName = @database, @LogToTable = @LogToTable,
                 @Execute = @Execute;

		-- restore diff backup  
		IF @FullRecovery='Y' AND @DiffRecovery = 'Y' AND @lastDiffBackupDate IS NOT NULL 
		BEGIN 
			SET @cmd = 'RESTORE DATABASE ['+@RestoreDatabaseName+'] FROM DISK = '''+@FullCopyPath+@lastDiffBackup+''' WITH FILE = 1 ';
			IF @LogRecovery = 'Y' 
				SET @cmd = @cmd + ', NORECOVERY'
			EXECUTE @cmd = [dbo].[sp_CommandExecute]	@Command = @cmd, @CommandType = 'RESTORE DATABASE',	@Mode = 1,
					@DatabaseName = @database, @LogToTable = @LogToTable, @Execute = @Execute;
		END 

		--  - Find logs after full backup and restore
		IF @FullRecovery='Y' AND @LogRecovery = 'Y' BEGIN -- THE FULLBACKUP SHOULD BE IN THE SCANNED FOLDER
			DECLARE LogFiles CURSOR FOR
				SELECT backupFile FROM @fileListForRestore WHERE  BackType = 'LOG' ORDER BY WhenDate ASC

				--SELECT REVERSE( LEFT(REVERSE(backupFile),CHARINDEX(' ',REVERSE(backupFile))-1 ) ) --borrowed from Kin Shah/Aaron's on dba.stackexchange.com		
				--FROM @fileList  
				--WHERE backupFile LIKE '%.TRN'  AND backupFile LIKE '%'+@database+'%' AND CONVERT(DATETIME,SUBSTRING(backupFile,1,20),101) >  CASE WHEN @lastDiffBackupDate IS NOT NULL THEN @lastDiffBackupDate ELSE @lastFullBackupDate END
				--ORDER BY CONVERT(DATETIME,SUBSTRING(backupFile,1,20),101) ASC
		
			OPEN LogFiles
			FETCH NEXT FROM LogFiles INTO @backupFile  

			WHILE @@FETCH_STATUS = 0  
			BEGIN  
				SET @cmd = 'RESTORE LOG [' + @database + '] FROM DISK = '''  + @backupPath + @backupFile + ''' WITH NORECOVERY' 
				EXECUTE @cmd = [dbo].[sp_CommandExecute] @Command = @cmd, @CommandType = 'RESTORE LOG', @Mode = 1, @DatabaseName = @database,
						@LogToTable = @LogToTable, @Execute = @Execute; 
				FETCH NEXT FROM LogFiles INTO @backupFile  
			END 
			CLOSE LogFiles  
			DEALLOCATE LogFiles  
		END
			   select @lastFullBackup lastFullBackup,@lastDiffBackup lastDiffBackup, @firstLogBackup firstLogBackup
			   select @lastFullBackupDate lastFullBackupDate, @lastDiffBackupDate lastDiffBackupDate, @FirstLogBackupDate FirstLogBackupDate


    
   --    --Run a checkdb against this database         
		 --IF @RunCheckDB = 'Y'
   --         EXECUTE [dbo].[DatabaseIntegrityCheck] @Databases = @database, @LogToTable = @LogToTable;

         IF @TestRestore = 'Y'
         BEGIN
			SET @Cmd = 'ALTER DATABASE [' + @database+ '] SET SINGLE_USER WITH ROLLBACK IMMEDIATE '
			EXECUTE sp_executesql  @CMD;
			SET @Cmd = 'DROP DATABASE ['+@database + ']';
			EXECUTE sp_executesql @CMD;
         END;
		 
	  
	    -- put database in a USEABLE STATE
		IF @LogRecovery = 'Y'  BEGIN
		  SET @cmd = 'RESTORE DATABASE [' + @database + '] WITH RECOVERY' 
		  EXECUTE @cmd = [dbo].[sp_CommandExecute]
						@Command = @cmd,
						@CommandType = 'USEABLE STATE',
						@Mode = 1,
						@DatabaseName = @database,
						@LogToTable = @LogToTable,
						@Execute = @Execute;
	   END

END


