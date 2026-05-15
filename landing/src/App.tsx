import {
  Box,
  Button,
  Container,
  Flex,
  HStack,
  Heading,
  IconButton,
  Image,
  SimpleGrid,
  Stack,
  Text,
  VStack,
  useColorMode,
  useColorModeValue,
  Icon,
  Link,
  Tag,
} from "@chakra-ui/react";
import {
  FiDownload,
  FiMoon,
  FiSun,
  FiFolder,
  FiZap,
  FiLayout,
  FiEye,
  FiGithub,
  FiLayers,
  FiSettings,
} from "react-icons/fi";

const APP_VERSION = "0.3.2";
const DMG_URL = `/FocusDock-${APP_VERSION}.dmg`;

function Nav() {
  const { colorMode, toggleColorMode } = useColorMode();
  const bg = useColorModeValue("whiteAlpha.800", "blackAlpha.600");
  return (
    <Box
      as="nav"
      position="sticky"
      top={0}
      zIndex={10}
      backdropFilter="saturate(180%) blur(20px)"
      bg={bg}
      borderBottomWidth="1px"
      borderColor={useColorModeValue("blackAlpha.100", "whiteAlpha.100")}
    >
      <Container maxW="6xl" py={3}>
        <Flex align="center" justify="space-between">
          <HStack spacing={2}>
            <Box
              boxSize="28px"
              borderRadius="8px"
              bgGradient="linear(135deg, #5b8def, #9b59ff)"
            />
            <Text fontWeight={700} fontSize="lg" letterSpacing="-0.01em">
              Focus Dock
            </Text>
            <Tag size="sm" colorScheme="purple" variant="subtle" ml={1}>
              v{APP_VERSION}
            </Tag>
          </HStack>
          <HStack spacing={2}>
            <Button
              as="a"
              href={DMG_URL}
              size="sm"
              colorScheme="purple"
              leftIcon={<FiDownload />}
            >
              Download
            </Button>
            <IconButton
              aria-label="Toggle color mode"
              size="sm"
              variant="ghost"
              onClick={toggleColorMode}
              icon={colorMode === "dark" ? <FiSun /> : <FiMoon />}
            />
          </HStack>
        </Flex>
      </Container>
    </Box>
  );
}

function Hero() {
  const subtle = useColorModeValue("gray.600", "gray.400");
  const tagBg = useColorModeValue("blackAlpha.50", "whiteAlpha.100");
  return (
    <Container maxW="6xl" pt={{ base: 16, md: 24 }} pb={{ base: 12, md: 16 }}>
      <VStack spacing={8} textAlign="center">
        <Tag bg={tagBg} px={3} py={1} borderRadius="full">
          Free • macOS 13+ • Apple Silicon &amp; Intel
        </Tag>
        <Heading
          as="h1"
          size="3xl"
          fontWeight={800}
          letterSpacing="-0.03em"
          lineHeight="1.05"
          maxW="4xl"
        >
          The dock the Mac deserves.{" "}
          <Box
            as="span"
            bgGradient="linear(135deg, #5b8def, #9b59ff)"
            bgClip="text"
          >
            iOS-style folders, magnification, and parity.
          </Box>
        </Heading>
        <Text fontSize={{ base: "lg", md: "xl" }} color={subtle} maxW="3xl">
          Drag an app onto another, hold a second, and a folder forms —
          exactly like iOS. The one Dock feature Apple never shipped on the
          Mac. Plus crisp magnification, customizable everything, and a
          running-app view that finally matches macOS.
        </Text>
        <HStack spacing={3} pt={2}>
          <Button
            as="a"
            href={DMG_URL}
            size="lg"
            colorScheme="purple"
            leftIcon={<FiDownload />}
            px={8}
          >
            Download for macOS
          </Button>
          <Button
            as="a"
            href="https://github.com/The-Portland-Company/focus-dock-for-macos"
            size="lg"
            variant="ghost"
            leftIcon={<FiGithub />}
            target="_blank"
            rel="noopener"
          >
            View source
          </Button>
        </HStack>
        <Text fontSize="sm" color={subtle}>
          Open the DMG · drag <strong>Focus Dock</strong> into{" "}
          <strong>Applications</strong> · launch.
        </Text>
      </VStack>

      <Box mt={{ base: 12, md: 16 }}>
        <ScreenshotFrame src="/screenshots/hero.png" alt="Focus Dock on macOS" />
      </Box>
    </Container>
  );
}

function ScreenshotFrame({ src, alt }: { src: string; alt: string }) {
  const ring = useColorModeValue("blackAlpha.200", "whiteAlpha.200");
  const shadow = useColorModeValue(
    "0 30px 80px -20px rgba(0,0,0,0.25)",
    "0 30px 80px -10px rgba(0,0,0,0.6)",
  );
  return (
    <Box
      borderRadius="2xl"
      overflow="hidden"
      borderWidth="1px"
      borderColor={ring}
      boxShadow={shadow}
    >
      <Image src={src} alt={alt} w="100%" display="block" />
    </Box>
  );
}

const features = [
  {
    icon: FiFolder,
    title: "Drag-and-hold folders",
    body: "Drop an app onto another, hold ~0.8 s, icons begin to wiggle and a folder forms — exactly like iOS.",
  },
  {
    icon: FiZap,
    title: "Native-style magnification",
    body: "Smooth Gaussian falloff centered on the cursor. Icons pre-rasterized at 256×256 so they stay sharp at every scale.",
  },
  {
    icon: FiLayers,
    title: "Running-app parity",
    body: "Every running regular app appears in the dock — pinned or not — matching the native macOS Dock you remember.",
  },
  {
    icon: FiEye,
    title: "Minimized-window tiles",
    body: "Minimized windows surface as thumbnails in a protected right-hand zone. Click any tile to restore.",
  },
  {
    icon: FiLayout,
    title: "Snap to any edge",
    body: "Bottom, top, left, or right. Flush with the screen edge or floating. Auto-orients its icon row.",
  },
  {
    icon: FiSettings,
    title: "Tune everything",
    body: "Icon size, spacing, padding, corner radius, border, tint, magnify amount. Reset any control with one click.",
  },
];

function Features() {
  const cardBg = useColorModeValue("white", "whiteAlpha.50");
  const cardBorder = useColorModeValue("blackAlpha.100", "whiteAlpha.100");
  const iconBg = useColorModeValue("purple.50", "purple.900");
  const iconColor = useColorModeValue("purple.600", "purple.200");
  const subtle = useColorModeValue("gray.600", "gray.400");
  return (
    <Container maxW="6xl" py={{ base: 16, md: 24 }}>
      <VStack spacing={4} textAlign="center" mb={12}>
        <Heading size="xl" letterSpacing="-0.02em">
          Every detail, the way it should have been.
        </Heading>
        <Text fontSize="lg" color={subtle} maxW="2xl">
          A real replacement dock — not a launcher, not a wrapper. Replaces
          the native Dock on launch; restores it on quit.
        </Text>
      </VStack>
      <SimpleGrid columns={{ base: 1, md: 2, lg: 3 }} spacing={6}>
        {features.map((f) => (
          <Box
            key={f.title}
            bg={cardBg}
            borderWidth="1px"
            borderColor={cardBorder}
            borderRadius="xl"
            p={6}
          >
            <Flex
              boxSize="40px"
              borderRadius="lg"
              bg={iconBg}
              align="center"
              justify="center"
              mb={4}
            >
              <Icon as={f.icon} boxSize="20px" color={iconColor} />
            </Flex>
            <Heading size="md" mb={2} letterSpacing="-0.01em">
              {f.title}
            </Heading>
            <Text color={subtle}>{f.body}</Text>
          </Box>
        ))}
      </SimpleGrid>
    </Container>
  );
}

function Screenshots() {
  const subtle = useColorModeValue("gray.600", "gray.400");
  return (
    <Box bg={useColorModeValue("blackAlpha.50", "whiteAlpha.50")} py={{ base: 16, md: 24 }}>
      <Container maxW="6xl">
        <VStack spacing={4} textAlign="center" mb={12}>
          <Heading size="xl" letterSpacing="-0.02em">
            Tune it until it disappears.
          </Heading>
          <Text fontSize="lg" color={subtle} maxW="2xl">
            Light, dark, flush, floating, big, tiny. The Settings panel has
            a slider for every detail — and a reset arrow next to each one.
          </Text>
        </VStack>
        <Stack spacing={6}>
          <ScreenshotFrame
            src="/screenshots/settings.png"
            alt="Focus Dock Settings panel"
          />
          <ScreenshotFrame
            src="/screenshots/dock-only.png"
            alt="Focus Dock rendered at the bottom of the screen"
          />
        </Stack>
      </Container>
    </Box>
  );
}

function Download() {
  const cardBg = useColorModeValue("white", "whiteAlpha.50");
  const cardBorder = useColorModeValue("blackAlpha.100", "whiteAlpha.100");
  const subtle = useColorModeValue("gray.600", "gray.400");
  return (
    <Container maxW="4xl" py={{ base: 16, md: 24 }}>
      <Box
        bg={cardBg}
        borderWidth="1px"
        borderColor={cardBorder}
        borderRadius="2xl"
        p={{ base: 8, md: 12 }}
        textAlign="center"
      >
        <Heading size="xl" mb={3} letterSpacing="-0.02em">
          Try it. It's free.
        </Heading>
        <Text color={subtle} mb={8} fontSize="lg">
          One small DMG. No account, no telemetry. Quit it any time and the
          system Dock comes right back.
        </Text>
        <VStack spacing={3}>
          <Button
            as="a"
            href={DMG_URL}
            size="lg"
            colorScheme="purple"
            leftIcon={<FiDownload />}
            px={10}
          >
            Download Focus Dock {APP_VERSION}
          </Button>
          <Text fontSize="sm" color={subtle}>
            ~1.4 MB · macOS 13.0 or newer · Apple Silicon &amp; Intel
          </Text>
        </VStack>
      </Box>
    </Container>
  );
}

function Footer() {
  const subtle = useColorModeValue("gray.600", "gray.400");
  const border = useColorModeValue("blackAlpha.100", "whiteAlpha.100");
  return (
    <Box borderTopWidth="1px" borderColor={border} py={10}>
      <Container maxW="6xl">
        <Flex
          direction={{ base: "column", md: "row" }}
          align="center"
          justify="space-between"
          gap={4}
        >
          <Text fontSize="sm" color={subtle}>
            © {new Date().getFullYear()} The Portland Company.
          </Text>
          <HStack spacing={6} fontSize="sm" color={subtle}>
            <Link
              href="https://github.com/The-Portland-Company/focus-dock-for-macos"
              isExternal
            >
              GitHub
            </Link>
            <Link href={DMG_URL}>Download</Link>
          </HStack>
        </Flex>
      </Container>
    </Box>
  );
}

export default function App() {
  return (
    <Box>
      <Nav />
      <Hero />
      <Features />
      <Screenshots />
      <Download />
      <Footer />
    </Box>
  );
}
